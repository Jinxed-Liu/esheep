import CryptoKit
import Foundation
import SwiftData

enum InsightPersonalSyncError: LocalizedError {
    case deviceApprovalRequired
    case invalidCiphertextRecord

    var errorDescription: String? {
        switch self {
        case .deviceApprovalRequired:
            "这台设备尚未获准访问洞察空间，请在已授权设备上批准，或使用恢复码。"
        case .invalidCiphertextRecord:
            "云端洞察密文格式无效。"
        }
    }
}

private struct InsightSyncEnvelope: Codable {
    let version: Int
    let recordKind: String
    let payload: Data
}

private struct InsightConversationPayload: Codable {
    let id: UUID
    let accountID: UUID
    let farmID: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let revision: Int64
}

private struct InsightMessagePayload: Codable {
    let id: UUID
    let conversationID: UUID
    let accountID: UUID
    let farmID: UUID
    let roleRawValue: String
    let text: String
    let createdAt: Date
    let updatedAt: Date
    let statusRawValue: String
    let provider: String
    let model: String
    let errorMessage: String?
    let providerResponseID: String?
    let toolName: String?
}

private struct InsightAttachmentPayload: Codable {
    let id: UUID
    let conversationID: UUID
    let messageID: UUID?
    let accountID: UUID
    let farmID: UUID
    let mimeType: String
    let imageData: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let digest: String
    let createdAt: Date
    let deletedAt: Date?
}

private struct InsightDraftPayload: Codable {
    let id: UUID
    let conversationID: UUID
    let messageID: UUID?
    let accountID: UUID
    let farmID: UUID
    let originDeviceID: UUID
    let toolName: String
    let title: String
    let summary: String
    let argumentsJSON: Data
    let riskRawValue: String
    let requiredCapabilityRawValue: String
    let expectedEntityID: UUID?
    let expectedRevision: Int?
    let reason: String
    let statusRawValue: String
    let createdAt: Date
    let updatedAt: Date
    let executedOperationID: UUID?
    let errorMessage: String?
}

private struct InsightReceiptPayload: Codable {
    let sourceRequestID: UUID
    let accountID: UUID
    let farmID: UUID
    let operationID: UUID
    let entityType: String
    let entityID: UUID?
    let createdAt: Date
}

@MainActor
final class InsightPersonalSyncActor {
    static let shared = InsightPersonalSyncActor()

    private let worker: IdentityWorkerClient
    private let crypto: InsightPersonalCryptoActor
    private let deviceKeys: InsightDeviceKeyAgreementActor
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        worker: IdentityWorkerClient = .shared,
        crypto: InsightPersonalCryptoActor = .shared,
        deviceKeys: InsightDeviceKeyAgreementActor = .shared
    ) {
        self.worker = worker
        self.crypto = crypto
        self.deviceKeys = deviceKeys
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func synchronize(accountID: UUID, context: ModelContext) async {
        guard IdentityWorkerConfiguration.baseURL != nil else { return }
        let state = syncState(accountID: accountID, context: context)
        do {
            let preparedDevice = try await prepareDevice(accountID: accountID)
            var records = try await makeOutgoing(accountID: accountID, context: context)
            var cursor = Int64(state.cursor ?? "0") ?? 0
            repeat {
                let batch = Array(records.prefix(200))
                if !batch.isEmpty { records.removeFirst(batch.count) }
                let response = try await worker.syncInsightRecords(
                    deviceID: preparedDevice.deviceID,
                    cursor: cursor,
                    records: batch
                )
                guard response.keyVersion == preparedDevice.keyVersion else {
                    throw InsightPersonalSyncError.deviceApprovalRequired
                }
                try await apply(response.records, accountID: accountID, context: context)
                cursor = response.cursor
                if batch.isEmpty && !response.hasMore { break }
            } while !records.isEmpty

            while true {
                let response = try await worker.syncInsightRecords(
                    deviceID: preparedDevice.deviceID,
                    cursor: cursor,
                    records: []
                )
                guard response.keyVersion == preparedDevice.keyVersion else {
                    throw InsightPersonalSyncError.deviceApprovalRequired
                }
                try await apply(response.records, accountID: accountID, context: context)
                cursor = response.cursor
                if !response.hasMore { break }
            }
            try pruneExpiredTombstones(accountID: accountID, context: context)
            state.cursor = String(cursor)
            state.lastPulledAt = .now
            state.lastPushedAt = .now
            state.lastErrorMessage = nil
            try context.save()
        } catch {
            state.lastErrorMessage = error.localizedDescription
            try? context.save()
        }
    }

    func approve(
        device: WorkerInsightDeviceList.Device,
        accountID: UUID
    ) async throws {
        try await InsightBiometricConfirmation.authenticate(reason: "批准新设备访问洞察历史和 MiMo API Key")
        let approver = try await deviceKeys.identity()
        guard let targetPublicKey = Self.x963Representation(from: device.publicKeyJWK) else {
            throw InsightSecurityError.invalidEnvelope
        }
        let envelope = try await crypto.makeEnvelope(
            for: accountID,
            targetDeviceID: device.deviceID,
            targetPublicKeyX963: targetPublicKey
        )
        let data = try encoder.encode(envelope)
        _ = try await worker.approveInsightDevice(
            deviceID: device.deviceID,
            approverDeviceID: approver.deviceID,
            keyVersion: envelope.keyVersion,
            sealedEnvelope: data
        )
    }

    func revoke(
        device: WorkerInsightDeviceList.Device,
        accountID: UUID,
        context: ModelContext
    ) async throws {
        try await InsightBiometricConfirmation.authenticate(
            reason: "撤销设备并轮换洞察空间加密密钥"
        )
        let preparedDevice = try await prepareDevice(accountID: accountID)
        guard device.deviceID != preparedDevice.deviceID, device.status == "active" else {
            throw InsightSecurityError.invalidEnvelope
        }
        let devices = try await worker.insightDevices().devices
        let remaining = devices.filter {
            $0.status == "active" && $0.deviceID != device.deviceID
        }
        guard remaining.contains(where: { $0.deviceID == preparedDevice.deviceID }) else {
            throw InsightPersonalSyncError.deviceApprovalRequired
        }
        let candidate = try await crypto.prepareRotation(
            for: accountID,
            nextKeyVersion: preparedDevice.keyVersion + 1
        )
        do {
            var rotationEnvelopes: [WorkerInsightRotationEnvelope] = []
            for target in remaining {
                guard let publicKey = Self.x963Representation(from: target.publicKeyJWK) else {
                    throw InsightSecurityError.invalidEnvelope
                }
                let envelope = try await crypto.makeEnvelope(
                    using: candidate,
                    targetDeviceID: target.deviceID,
                    targetPublicKeyX963: publicKey
                )
                rotationEnvelopes.append(WorkerInsightRotationEnvelope(
                    targetDeviceID: target.deviceID,
                    sealedEnvelopeBase64: try encoder.encode(envelope).base64EncodedString()
                ))
            }
            let response = try await worker.revokeInsightDevice(
                deviceID: device.deviceID,
                requesterDeviceID: preparedDevice.deviceID,
                keyVersion: candidate.keyVersion,
                envelopes: rotationEnvelopes
            )
            guard response.status == "revoked", response.keyVersion == candidate.keyVersion else {
                throw InsightSecurityError.invalidEnvelope
            }
            try await crypto.commitRotation(candidate)
            let state = syncState(accountID: accountID, context: context)
            state.cursor = "0"
            try context.save()
            await synchronize(accountID: accountID, context: context)
        } catch {
            try? await crypto.discardRotation(candidate)
            throw error
        }
    }

    func currentDeviceID() async throws -> UUID {
        try await deviceKeys.identity().deviceID
    }

    func exportRecovery(accountID: UUID) async throws -> InsightRecoveryExport {
        try await InsightBiometricConfirmation.authenticate(reason: "生成洞察空间恢复码")
        let preparedDevice = try await prepareDevice(accountID: accountID)
        let value = try await crypto.exportRecovery(for: accountID)
        let proofDigest = SHA256.hash(data: value.authorizationSecret)
            .map { String(format: "%02x", $0) }
            .joined()
        try await worker.updateInsightRecovery(
            deviceID: preparedDevice.deviceID,
            keyVersion: value.package.keyVersion,
            ciphertext: encoder.encode(value.package),
            proofDigest: proofDigest
        )
        return value
    }

    func importRecovery(
        code: String,
        accountID: UUID,
        context: ModelContext
    ) async throws {
        let identity = try await deviceKeys.identity()
        let device = try await worker.requestInsightDevice(
            deviceID: identity.deviceID,
            publicKeyJWK: identity.publicKeyJWK,
            displayName: "此 iPhone"
        )
        if device.status == "active" {
            let prepared = try await prepareDevice(accountID: accountID)
            guard prepared.keyVersion == device.keyVersion else {
                throw InsightPersonalSyncError.deviceApprovalRequired
            }
            let state = syncState(accountID: accountID, context: context)
            state.cursor = "0"
            try context.save()
            await synchronize(accountID: accountID, context: context)
            return
        }
        guard device.status == "pending" else {
            throw InsightPersonalSyncError.deviceApprovalRequired
        }
        guard let value = try await worker.insightRecovery().recovery,
              let data = Data(base64Encoded: value.ciphertextBase64) else {
            throw InsightSecurityError.invalidRecoveryCode
        }
        let package = try decoder.decode(InsightRecoveryPackage.self, from: data)
        guard package.keyVersion == value.keyVersion,
              package.keyVersion == device.keyVersion else {
            throw InsightSecurityError.invalidRecoveryCode
        }
        let authorizationSecret = try await crypto.importRecovery(
            package,
            code: code,
            accountID: accountID
        )
        let envelope = try await crypto.makeEnvelope(
            for: accountID,
            targetDeviceID: identity.deviceID,
            targetPublicKeyX963: identity.publicKeyX963
        )
        guard envelope.keyVersion == package.keyVersion else {
            throw InsightSecurityError.invalidEnvelope
        }
        let recovered = try await worker.recoverInsightDevice(
            deviceID: identity.deviceID,
            keyVersion: package.keyVersion,
            recoveryProof: authorizationSecret,
            sealedEnvelope: encoder.encode(envelope)
        )
        guard recovered.status == "active",
              recovered.keyVersion == package.keyVersion else {
            throw InsightPersonalSyncError.deviceApprovalRequired
        }
        let state = syncState(accountID: accountID, context: context)
        state.cursor = "0"
        try context.save()
        await synchronize(accountID: accountID, context: context)
    }

    private func prepareDevice(
        accountID: UUID
    ) async throws -> (deviceID: UUID, keyVersion: Int) {
        let identity = try await deviceKeys.identity()
        let response = try await worker.requestInsightDevice(
            deviceID: identity.deviceID,
            publicKeyJWK: identity.publicKeyJWK,
            displayName: "此 iPhone"
        )
        let serverKeyVersion = response.keyVersion ?? 1
        let envelopes = try await worker.insightKeyEnvelopes(deviceID: identity.deviceID).envelopes
        let latest = envelopes.max(by: { $0.keyVersion < $1.keyVersion })
        let hasLocalKey = await crypto.hasMasterKey(for: accountID)
        let localKeyVersion = await crypto.keyVersion(for: accountID)
        if let latest,
           (!hasLocalKey || latest.keyVersion > localKeyVersion),
           let data = Data(base64Encoded: latest.sealedEnvelopeBase64) {
            let envelope = try decoder.decode(InsightKeyEnvelope.self, from: data)
            try await crypto.importEnvelope(envelope, for: accountID)
        } else if response.status == "active", !hasLocalKey, serverKeyVersion == 1 {
            _ = try await crypto.createMasterKeyIfNeeded(for: accountID)
        }
        guard response.status == "active",
              await crypto.hasMasterKey(for: accountID),
              await crypto.keyVersion(for: accountID) == serverKeyVersion else {
            throw InsightPersonalSyncError.deviceApprovalRequired
        }
        return (identity.deviceID, serverKeyVersion)
    }

    private func makeOutgoing(
        accountID: UUID,
        context: ModelContext
    ) async throws -> [WorkerInsightSyncRecord] {
        var records: [WorkerInsightSyncRecord] = []
        for value in try context.fetch(FetchDescriptor<InsightConversationRecord>()) where value.accountID == accountID {
            let payload = InsightConversationPayload(
                id: value.id,
                accountID: value.accountID,
                farmID: value.farmID,
                title: value.title,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt,
                deletedAt: value.deletedAt,
                revision: value.revision
            )
            records.append(try await record(
                id: value.id,
                kind: "conversation",
                conversationID: value.id,
                revision: value.revision,
                deletedAt: value.deletedAt,
                payload: payload,
                accountID: accountID
            ))
        }
        for value in try context.fetch(FetchDescriptor<InsightMessageRecord>()) where value.accountID == accountID {
            let payload = InsightMessagePayload(
                id: value.id,
                conversationID: value.conversationID,
                accountID: value.accountID,
                farmID: value.farmID,
                roleRawValue: value.roleRawValue,
                text: value.text,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt,
                statusRawValue: value.statusRawValue,
                provider: value.provider,
                model: value.model,
                errorMessage: value.errorMessage,
                providerResponseID: value.providerResponseID,
                toolName: value.toolName
            )
            records.append(try await record(
                id: value.id,
                kind: "message",
                conversationID: value.conversationID,
                revision: Self.revision(value.updatedAt),
                payload: payload,
                accountID: accountID
            ))
        }
        for value in try context.fetch(FetchDescriptor<InsightAttachmentRecord>())
        where value.accountID == accountID {
            guard let imageData = value.imageData else { continue }
            let payload = InsightAttachmentPayload(
                id: value.id,
                conversationID: value.conversationID,
                messageID: value.messageID,
                accountID: value.accountID,
                farmID: value.farmID,
                mimeType: value.mimeType,
                imageData: imageData,
                pixelWidth: value.pixelWidth,
                pixelHeight: value.pixelHeight,
                digest: value.digest,
                createdAt: value.createdAt,
                deletedAt: value.deletedAt
            )
            records.append(try await record(
                id: value.id,
                kind: "attachment",
                conversationID: value.conversationID,
                revision: Self.revision(value.createdAt),
                deletedAt: value.deletedAt,
                payload: payload,
                accountID: accountID
            ))
        }
        let actionDrafts = try context.fetch(FetchDescriptor<InsightActionDraftRecord>())
            .filter { $0.accountID == accountID }
        for value in actionDrafts {
            let payload = InsightDraftPayload(
                id: value.id,
                conversationID: value.conversationID,
                messageID: value.messageID,
                accountID: value.accountID,
                farmID: value.farmID,
                originDeviceID: value.originDeviceID,
                toolName: value.toolName,
                title: value.title,
                summary: value.summary,
                argumentsJSON: value.argumentsJSON,
                riskRawValue: value.riskRawValue,
                requiredCapabilityRawValue: value.requiredCapabilityRawValue,
                expectedEntityID: value.expectedEntityID,
                expectedRevision: value.expectedRevision,
                reason: value.reason,
                statusRawValue: value.statusRawValue,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt,
                executedOperationID: value.executedOperationID,
                errorMessage: value.errorMessage
            )
            records.append(try await record(
                id: value.id,
                kind: "action_draft",
                conversationID: value.conversationID,
                revision: Self.revision(value.updatedAt),
                payload: payload,
                accountID: accountID
            ))
        }
        var draftConversationIDs = Dictionary(
            uniqueKeysWithValues: actionDrafts.map { ($0.id, $0.conversationID) }
        )
        for draft in actionDrafts where draft.toolName == "draft_record_weaning" {
            draftConversationIDs[
                WeaningWorkflow.transferSourceRequestID(for: draft.id)
            ] = draft.conversationID
        }
        for value in try context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>()) where value.accountID == accountID {
            let payload = InsightReceiptPayload(
                sourceRequestID: value.sourceRequestID,
                accountID: value.accountID,
                farmID: value.farmID,
                operationID: value.operationID,
                entityType: value.entityType,
                entityID: value.entityID,
                createdAt: value.createdAt
            )
            records.append(try await record(
                id: value.sourceRequestID,
                kind: "receipt",
                conversationID: draftConversationIDs[value.sourceRequestID],
                revision: Self.revision(value.createdAt),
                payload: payload,
                accountID: accountID
            ))
        }
        if let encryptedCredential = try await MiMoCredentialVault.shared.encryptedCredential(
            for: accountID,
            crypto: crypto
        ) {
            let id = StableCloudUUID.derived(namespace: accountID, name: "insight-mimo-vault")
            let updatedAt = try await MiMoCredentialVault.shared.updateDate(for: accountID) ?? .now
            records.append(try await record(
                id: id,
                kind: "vault",
                revision: Self.revision(updatedAt),
                rawPayload: encryptedCredential,
                accountID: accountID
            ))
        } else if let deletedAt = try await MiMoCredentialVault.shared.deletionDate(for: accountID) {
            let id = StableCloudUUID.derived(namespace: accountID, name: "insight-mimo-vault")
            records.append(try await record(
                id: id,
                kind: "vault",
                revision: Self.revision(deletedAt),
                deletedAt: deletedAt,
                rawPayload: Data(),
                accountID: accountID
            ))
        }
        return records.sorted { $0.recordID.uuidString < $1.recordID.uuidString }
    }

    private func record<Payload: Encodable>(
        id: UUID,
        kind: String,
        conversationID: UUID? = nil,
        revision: Int64,
        deletedAt: Date? = nil,
        payload: Payload,
        accountID: UUID
    ) async throws -> WorkerInsightSyncRecord {
        try await record(
            id: id,
            kind: kind,
            conversationID: conversationID,
            revision: revision,
            deletedAt: deletedAt,
            rawPayload: encoder.encode(payload),
            accountID: accountID
        )
    }

    private func record(
        id: UUID,
        kind: String,
        conversationID: UUID? = nil,
        revision: Int64,
        deletedAt: Date? = nil,
        rawPayload: Data,
        accountID: UUID
    ) async throws -> WorkerInsightSyncRecord {
        let envelope = InsightSyncEnvelope(version: 1, recordKind: kind, payload: rawPayload)
        let sealed = try await crypto.seal(
            encoder.encode(envelope),
            accountID: accountID,
            recordID: id.uuidString.lowercased()
        )
        return WorkerInsightSyncRecord(
            recordID: id,
            recordKind: kind,
            conversationID: conversationID,
            revision: max(1, revision),
            ciphertextBase64: sealed.base64EncodedString(),
            deletedAt: deletedAt.map { Self.revision($0) },
            updatedAt: nil
        )
    }

    private func apply(
        _ records: [WorkerInsightSyncRecord],
        accountID: UUID,
        context: ModelContext
    ) async throws {
        for record in records {
            guard let sealed = Data(base64Encoded: record.ciphertextBase64) else {
                throw InsightPersonalSyncError.invalidCiphertextRecord
            }
            let plaintext = try await crypto.open(
                sealed,
                accountID: accountID,
                recordID: record.recordID.uuidString.lowercased()
            )
            let envelope = try decoder.decode(InsightSyncEnvelope.self, from: plaintext)
            guard envelope.version == 1, envelope.recordKind == record.recordKind else {
                throw InsightPersonalSyncError.invalidCiphertextRecord
            }
            switch record.recordKind {
            case "conversation":
                let value = try decoder.decode(InsightConversationPayload.self, from: envelope.payload)
                guard value.accountID == accountID,
                      record.conversationID == nil || record.conversationID == value.id else {
                    throw InsightPersonalSyncError.invalidCiphertextRecord
                }
                try applyConversation(value, context: context)
            case "message":
                let value = try decoder.decode(InsightMessagePayload.self, from: envelope.payload)
                guard value.accountID == accountID,
                      record.conversationID == nil || record.conversationID == value.conversationID else {
                    throw InsightPersonalSyncError.invalidCiphertextRecord
                }
                try applyMessage(value, context: context)
            case "attachment":
                let value = try decoder.decode(InsightAttachmentPayload.self, from: envelope.payload)
                guard value.accountID == accountID,
                      record.conversationID == nil || record.conversationID == value.conversationID else {
                    throw InsightPersonalSyncError.invalidCiphertextRecord
                }
                try applyAttachment(value, context: context)
            case "action_draft":
                let value = try decoder.decode(InsightDraftPayload.self, from: envelope.payload)
                guard value.accountID == accountID,
                      record.conversationID == nil || record.conversationID == value.conversationID else {
                    throw InsightPersonalSyncError.invalidCiphertextRecord
                }
                try applyDraft(value, context: context)
            case "receipt":
                let value = try decoder.decode(InsightReceiptPayload.self, from: envelope.payload)
                guard value.accountID == accountID else {
                    throw InsightPersonalSyncError.invalidCiphertextRecord
                }
                try applyReceipt(value, context: context)
            case "vault":
                if record.deletedAt != nil {
                    try await MiMoCredentialVault.shared.remove(for: accountID)
                } else {
                    try await MiMoCredentialVault.shared.importEncryptedCredential(
                        envelope.payload,
                        for: accountID,
                        crypto: crypto
                    )
                }
            default:
                continue
            }
        }
        try context.save()
    }

    private func applyConversation(_ value: InsightConversationPayload, context: ModelContext) throws {
        guard let current = try context.fetch(FetchDescriptor<InsightConversationRecord>()).first(where: {
            $0.id == value.id
        }) else {
            let record = InsightConversationRecord(
                id: value.id,
                accountID: value.accountID,
                farmID: value.farmID,
                title: value.title,
                createdAt: value.createdAt,
                revision: value.revision
            )
            record.updatedAt = value.updatedAt
            record.deletedAt = value.deletedAt
            context.insert(record)
            return
        }
        guard value.revision >= current.revision else { return }
        current.title = value.title
        current.updatedAt = value.updatedAt
        current.deletedAt = value.deletedAt
        current.revision = value.revision
    }

    private func applyMessage(_ value: InsightMessagePayload, context: ModelContext) throws {
        if let current = try context.fetch(FetchDescriptor<InsightMessageRecord>()).first(where: { $0.id == value.id }) {
            guard value.updatedAt >= current.updatedAt else { return }
            current.text = value.text
            current.updatedAt = value.updatedAt
            current.statusRawValue = value.statusRawValue
            current.errorMessage = value.errorMessage
            current.providerResponseID = value.providerResponseID
            return
        }
        let record = InsightMessageRecord(
            id: value.id,
            conversationID: value.conversationID,
            accountID: value.accountID,
            farmID: value.farmID,
            role: InsightMessageRole(rawValue: value.roleRawValue) ?? .assistant,
            text: value.text,
            createdAt: value.createdAt,
            status: InsightMessageStatus(rawValue: value.statusRawValue) ?? .completed,
            provider: value.provider,
            model: value.model,
            toolName: value.toolName
        )
        record.updatedAt = value.updatedAt
        record.errorMessage = value.errorMessage
        record.providerResponseID = value.providerResponseID
        context.insert(record)
    }

    private func applyAttachment(_ value: InsightAttachmentPayload, context: ModelContext) throws {
        guard try context.fetch(FetchDescriptor<InsightAttachmentRecord>()).contains(where: {
            $0.id == value.id
        }) == false else { return }
        let record = InsightAttachmentRecord(
            id: value.id,
            conversationID: value.conversationID,
            messageID: value.messageID,
            accountID: value.accountID,
            farmID: value.farmID,
            mimeType: value.mimeType,
            imageData: value.imageData,
            pixelWidth: value.pixelWidth,
            pixelHeight: value.pixelHeight,
            digest: value.digest
        )
        record.createdAt = value.createdAt
        record.deletedAt = value.deletedAt
        context.insert(record)
    }

    private func applyDraft(_ value: InsightDraftPayload, context: ModelContext) throws {
        if let current = try context.fetch(FetchDescriptor<InsightActionDraftRecord>()).first(where: {
            $0.id == value.id
        }) {
            guard value.updatedAt >= current.updatedAt else { return }
            current.summary = value.summary
            current.argumentsJSON = value.argumentsJSON
            current.reason = value.reason
            current.statusRawValue = value.statusRawValue
            current.updatedAt = value.updatedAt
            current.executedOperationID = value.executedOperationID
            current.errorMessage = value.errorMessage
            return
        }
        let record = InsightActionDraftRecord(
            id: value.id,
            conversationID: value.conversationID,
            messageID: value.messageID,
            accountID: value.accountID,
            farmID: value.farmID,
            originDeviceID: value.originDeviceID,
            toolName: value.toolName,
            title: value.title,
            summary: value.summary,
            argumentsJSON: value.argumentsJSON,
            risk: InsightActionRisk(rawValue: value.riskRawValue) ?? .high,
            requiredCapability: FarmCapability(rawValue: value.requiredCapabilityRawValue) ?? .recordProduction,
            expectedEntityID: value.expectedEntityID,
            expectedRevision: value.expectedRevision
        )
        record.reason = value.reason
        record.statusRawValue = value.statusRawValue
        record.createdAt = value.createdAt
        record.updatedAt = value.updatedAt
        record.executedOperationID = value.executedOperationID
        record.errorMessage = value.errorMessage
        context.insert(record)
    }

    private func applyReceipt(_ value: InsightReceiptPayload, context: ModelContext) throws {
        guard try context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>()).contains(where: {
            $0.sourceRequestID == value.sourceRequestID
        }) == false else { return }
        let record = InsightExecutionReceiptRecord(
            sourceRequestID: value.sourceRequestID,
            accountID: value.accountID,
            farmID: value.farmID,
            operationID: value.operationID,
            entityType: value.entityType,
            entityID: value.entityID
        )
        record.createdAt = value.createdAt
        context.insert(record)
    }

    private func syncState(accountID: UUID, context: ModelContext) -> InsightSyncStateRecord {
        if let value = try? context.fetch(FetchDescriptor<InsightSyncStateRecord>()).first(where: {
            $0.accountID == accountID
        }) {
            return value
        }
        let value = InsightSyncStateRecord(accountID: accountID)
        context.insert(value)
        return value
    }

    private func pruneExpiredTombstones(
        accountID: UUID,
        context: ModelContext
    ) throws {
        let cutoff = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
        let conversations = try context.fetch(FetchDescriptor<InsightConversationRecord>())
            .filter {
                $0.accountID == accountID &&
                    ($0.deletedAt ?? .distantFuture) <= cutoff
            }
        let conversationIDs = Set(conversations.map(\.id))
        guard !conversationIDs.isEmpty else {
            for attachment in try context.fetch(FetchDescriptor<InsightAttachmentRecord>())
            where attachment.accountID == accountID &&
                (attachment.deletedAt ?? .distantFuture) <= cutoff {
                context.delete(attachment)
            }
            return
        }
        let drafts = try context.fetch(FetchDescriptor<InsightActionDraftRecord>())
            .filter {
                $0.accountID == accountID &&
                    conversationIDs.contains($0.conversationID)
            }
        var draftIDs = Set(drafts.map(\.id))
        for draft in drafts where draft.toolName == "draft_record_weaning" {
            draftIDs.insert(WeaningWorkflow.transferSourceRequestID(for: draft.id))
        }
        for receipt in try context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>())
        where receipt.accountID == accountID && draftIDs.contains(receipt.sourceRequestID) {
            context.delete(receipt)
        }
        for draft in drafts { context.delete(draft) }
        for message in try context.fetch(FetchDescriptor<InsightMessageRecord>())
        where message.accountID == accountID && conversationIDs.contains(message.conversationID) {
            context.delete(message)
        }
        for attachment in try context.fetch(FetchDescriptor<InsightAttachmentRecord>())
        where attachment.accountID == accountID &&
            (conversationIDs.contains(attachment.conversationID) ||
                (attachment.deletedAt ?? .distantFuture) <= cutoff) {
            context.delete(attachment)
        }
        for conversation in conversations { context.delete(conversation) }
    }

    private static func revision(_ date: Date) -> Int64 {
        max(1, Int64(date.timeIntervalSince1970 * 1_000))
    }

    private static func x963Representation(from jwk: [String: String]) -> Data? {
        guard jwk["kty"] == "EC", jwk["crv"] == "P-256",
              let x = jwk["x"].flatMap(Data.init(base64URLString:)),
              let y = jwk["y"].flatMap(Data.init(base64URLString:)),
              x.count == 32, y.count == 32 else {
            return nil
        }
        return Data([0x04]) + x + y
    }
}

private extension Data {
    init?(base64URLString: String) {
        var value = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}
