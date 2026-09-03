import Foundation
import SwiftData
import SwiftUI
import UIKit

struct FarmConflictCenterView: View {
    @Query(sort: \SyncConflictRecord.detectedAt, order: .reverse)
    private var conflicts: [SyncConflictRecord]

    let account: AccountProfile
    let farm: FarmRecord

    private var unresolvedConflicts: [SyncConflictRecord] {
        conflicts.filter {
            $0.farmID == farm.id &&
                ($0.statusRawValue == SyncConflictStatus.unresolved.rawValue ||
                    $0.statusRawValue == SyncConflictStatus.quarantined.rawValue)
        }
    }

    var body: some View {
        List(unresolvedConflicts, id: \.id) { conflict in
            NavigationLink {
                FarmConflictDetailView(
                    account: account,
                    farm: farm,
                    conflict: conflict
                )
            } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: conflict.displayName)
                            .font(.headline)
                        Text(LocalizedStringKey(conflict.businessTypeName))
                            .foregroundStyle(.secondary)
                        Text("冲突原因：\(conflict.reasonCodeDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("版本：本地 \(conflict.localRevision) / 云端 \(conflict.remoteRevision)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(
                            conflict.detectedAt,
                            format: .dateTime.year().month().day().hour().minute()
                        )
                        .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if unresolvedConflicts.isEmpty {
                ContentUnavailableView(
                    "没有需要处理的数据异常",
                    systemImage: "checkmark.circle"
                )
            }
        }
        .navigationTitle("数据异常处理")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FarmConflictDetailView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration

    let account: AccountProfile
    let farm: FarmRecord
    let conflict: SyncConflictRecord

    @State private var note = ""
    @State private var mergedText = ""
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        List {
            Section("记录") {
                LabeledContent("名称") {
                    Text(verbatim: conflict.displayName)
                }
                LabeledContent("业务类型") {
                    Text(LocalizedStringKey(conflict.businessTypeName))
                }
                LabeledContent("冲突原因") {
                    Text(conflict.reasonCodeDescription)
                }
                LabeledContent("本地版本") {
                    Text(verbatim: "v\(conflict.localRevision)")
                }
                LabeledContent("云端版本") {
                    Text(verbatim: "v\(conflict.remoteRevision)")
                }
                LabeledContent("本地版本哈希") {
                    Text(conflict.localPayloadDigest)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("云端版本哈希") {
                    Text(conflict.remotePayloadDigest)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("发现时间") {
                    Text(
                        conflict.detectedAt,
                        format: .dateTime.year().month().day().hour().minute()
                    )
                }
                LabeledContent("远端设备") {
                    Text(conflict.remoteDeviceString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("这条记录在本机和 eSheep 云都发生过更改，请选择要保留的版本。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("复制冲突证据") {
                    UIPasteboard.general.string = conflict.exportText
                    message = "冲突证据已复制到剪贴板。"
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
            Section("数据摘要") {
                Text(conflict.localPayloadSummary)
                    .font(.footnote)
                    .textSelection(.enabled)
                Text(conflict.remotePayloadSummary)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
            Section("选择保留版本") {
                TextField("处理说明（可选）", text: $note, axis: .vertical)
                Button("保留本机版本") { resolve(.acceptLocal) }
                    .disabled(!canResolve)
                Button("采用云端版本") { resolve(.acceptRemote) }
                    .disabled(!canResolve)
                if conflict.entityType == CloudEntityType.note.rawValue {
                    TextField("合并后的备注", text: $mergedText, axis: .vertical)
                    Button("使用合并后的备注") {
                        resolve(.mergeText(mergedText))
                    }
                    .disabled(
                        !canResolve ||
                            mergedText.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    )
                }
                Text("选择后，App 会再次检查记录是否符合当前牧场的业务规则。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("选择记录版本")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "处理结果",
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )
        ) {
            Button("完成", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(message ?? ""))
        }
    }

    private var canResolve: Bool {
        CapabilitySet(role: farm.role).allows(.resolveConflicts) &&
            !isWorking &&
            (conflict.statusRawValue == SyncConflictStatus.unresolved.rawValue ||
                conflict.statusRawValue == SyncConflictStatus.quarantined.rawValue)
    }

    private func resolve(_ decision: ConflictResolutionDecision) {
        guard canResolve else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await collaboration.conflicts.resolve(
                    conflictID: conflict.id,
                    decision: decision,
                    note: note,
                    farm: FarmContext(
                        accountID: account.effectiveAccountID,
                        farmID: farm.id,
                        role: farm.role
                    )
                )
                await collaboration.synchronizeNow()
                message = "数据异常已处理，所选版本会自动保存。"
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

private extension SyncConflictRecord {
    var exportText: String {
        let note = resolutionNote
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return """
冲突ID: \(id.uuidString.lowercased())
实体类型: \(entityType)
实体ID: \(entityID.uuidString.lowercased())
本地版本: \(localRevision)
云端版本: \(remoteRevision)
原因: \(reasonCodeDescription)（\(reasonCode)）
本地哈希: \(localPayloadDigest)
云端哈希: \(remotePayloadDigest)
检测时间: \(detectedAt.formatted(date: .numeric, time: .standard))
本地摘要: \(localPayloadSummary)
云端摘要: \(remotePayloadSummary)
远端设备: \(remoteDeviceString)
备注: \(note.isEmpty ? "无" : note)
"""
    }

    var displayName: String {
        for payload in [localPayload, remotePayload] {
            guard let object = try? JSONSerialization.jsonObject(with: payload),
                  let dictionary = object as? [String: Any] else {
                continue
            }
            for key in ["name", "earTag", "title", "displayName", "subject"] {
                if let value = dictionary[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }
        return "\(businessTypeName)记录"
    }

    var businessTypeName: String {
        switch entityType {
        case CloudEntityType.farm.rawValue: "牧场"
        case CloudEntityType.pen.rawValue: "圈舍"
        case CloudEntityType.sheep.rawValue: "羊只"
        case CloudEntityType.weight.rawValue: "称重"
        case CloudEntityType.weaning.rawValue: "断奶"
        case CloudEntityType.transfer.rawValue: "转群"
        case CloudEntityType.removal.rawValue: "离场"
        case CloudEntityType.productionBatch.rawValue,
             CloudEntityType.batchMembership.rawValue: "生产批次"
        case CloudEntityType.feedIngredient.rawValue,
             CloudEntityType.feedRecipe.rawValue,
             CloudEntityType.feedRecipeComponent.rawValue,
             CloudEntityType.feed.rawValue,
             CloudEntityType.feedLine.rawValue,
             CloudEntityType.feedIngredientBatch.rawValue: "饲喂"
        case CloudEntityType.inventoryLot.rawValue,
             CloudEntityType.inventoryTransaction.rawValue: "库存"
        case CloudEntityType.health.rawValue,
             CloudEntityType.healthCatalogItem.rawValue,
             CloudEntityType.healthSubjectLink.rawValue,
             CloudEntityType.careBatch.rawValue,
             CloudEntityType.careRule.rawValue,
             CloudEntityType.careReminder.rawValue,
             CloudEntityType.alertDeferral.rawValue: "健康与照护"
        case CloudEntityType.reproduction.rawValue,
             CloudEntityType.semen.rawValue,
             CloudEntityType.semenDonor.rawValue,
             CloudEntityType.semenTransaction.rawValue,
             CloudEntityType.breedingProgram.rawValue,
             CloudEntityType.breedingProgramStep.rawValue,
             CloudEntityType.lambingOffspring.rawValue,
             CloudEntityType.pedigreeChange.rawValue: "繁殖"
        case CloudEntityType.note.rawValue: "备注"
        case CloudEntityType.photoAsset.rawValue: "照片"
        default: "牧场业务"
        }
    }

    var reasonCodeDescription: String {
        switch reasonCode {
        case "supabaseBaseRevisionMismatch":
            return "云端版本基线不匹配"
        case "remotePedigreeParentQualificationMismatch":
            return "父源信息发生冲突"
        case "blocked_by_predecessor_conflict":
            return "先前操作冲突阻断"
        default:
            return reasonCode.isEmpty ? "未知原因" : reasonCode
        }
    }

    var remoteDeviceString: String {
        if let accountID = remoteAccountID, let deviceID = remoteDeviceID {
            return "\(accountID.uuidString.lowercased()) / \(deviceID.uuidString.lowercased())"
        }
        if let accountID = remoteAccountID {
            return accountID.uuidString.lowercased()
        }
        return "未知设备"
    }

    var localPayloadSummary: String {
        payloadSummary(for: localPayload)
    }

    var remotePayloadSummary: String {
        payloadSummary(for: remotePayload)
    }

    private func payloadSummary(for payload: Data) -> String {
        guard let decoded = try? JSONSerialization.jsonObject(with: payload) else {
            return "当前记录为二进制数据（长度：\(payload.count) 字节）"
        }
        if let dictionary = decoded as? [String: Any] {
            var parts: [String] = []
            for key in ["name", "earTag", "title", "displayName", "subject", "revision", "entityType", "payloadType"] {
                if let value = dictionary[key] {
                    parts.append("\(key): \(value)")
                }
            }
            if !parts.isEmpty {
                return parts.joined(separator: " · ")
            }
            if let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
               let raw = String(data: data, encoding: .utf8) {
                return raw
            }
        }
        if let array = decoded as? [Any], let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
           let raw = String(data: data, encoding: .utf8) {
            return raw
        }
        return "解析后内容无法展示"
    }
}
