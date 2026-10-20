import SwiftUI
import Supabase

struct FarmNameSettingsView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    let farm: FarmRecord
    let generation: Int

    @State private var name = ""
    @State private var latinName = ""
    @State private var identity: ESheepCloudFarmIdentityV2?
    @State private var pending: RenameRequest?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var didSave = false

    private struct RenameRequest {
        let id: UUID
        let name: String
        let latinName: String?
        let revision: Int64
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var trimmedLatinName: String? {
        let value = latinName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        Form {
            Section {
                TextField("牧场名称", text: $name)
                    .autocorrectionDisabled()
                    .disabled(isWorking || farm.role != .owner)
                TextField("英文名或拼音名（选填）", text: $latinName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .disabled(isWorking || farm.role != .owner)
                if let identity {
                    LabeledContent("云端名称") { Text(verbatim: identity.name) }
                    LabeledContent("云端英文名／拼音名") { Text(verbatim: identity.latinName ?? "未填写") }
                }
                Button(isWorking ? LocalizedStringKey("正在保存…") : LocalizedStringKey("保存名称")) {
                    Task { await save() }
                }
                .disabled(isWorking || farm.role != .owner || identity == nil ||
                    !ESheepCloudFarmIdentityV2.validName(trimmedName) || (trimmedLatinName != nil && !ESheepCloudFarmIdentityV2.validName(trimmedLatinName!)) ||
                    (trimmedName == identity?.name && trimmedLatinName == identity?.latinName))
                if didSave {
                    Label("牧场名称已保存到云端", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } header: {
                Text("牧场名称")
            } footer: {
                Text("仅牧场所有者可以修改名称，每项最多 80 个字符。英文名或拼音名为全局牧场资料，会同步给牧场成员并用于分享海报；留空时海报隐藏此行。现有羊只和历史记录全部保留。")
            }
        }
        .navigationTitle("牧场名称")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .alert("无法保存牧场名称", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(errorMessage ?? ""))
        }
    }

    private func refresh() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let current = try await collaboration.eSheepCloudFarmIdentity(farmID: farm.id, generation: generation)
            identity = current
            name = current.name
            latinName = current.latinName ?? ""
        } catch {
            errorMessage = "暂时无法读取云端牧场名称，请联网后重新打开。"
        }
    }

    private func save() async {
        guard !isWorking, farm.role == .owner, let identity,
              ESheepCloudFarmIdentityV2.validName(trimmedName),
              trimmedLatinName == nil || ESheepCloudFarmIdentityV2.validName(trimmedLatinName!) else { return }
        let request: RenameRequest
        if let pending, pending.name == trimmedName, pending.latinName == trimmedLatinName { request = pending }
        else { request = .init(id: UUID(), name: trimmedName, latinName: trimmedLatinName, revision: identity.revision) }
        pending = request
        isWorking = true
        didSave = false
        defer { isWorking = false }
        do {
            let result = try await collaboration.renameESheepCloudFarm(farmID: farm.id, generation: generation,
                name: request.name, latinName: request.latinName, expectedRevision: request.revision, requestID: request.id)
            // An idempotent receipt may be older than another device's edit.
            let current = try await collaboration.eSheepCloudFarmIdentity(farmID: farm.id, generation: generation)
            self.identity = current
            name = current.name
            latinName = current.latinName ?? ""
            pending = nil
            didSave = current == result
            if current != result { errorMessage = "牧场名称已被其他设备更新，已显示最新云端名称。" }
        } catch let error as PostgrestError where error.code == "40001" {
            pending = nil
            if let current = try? await collaboration.eSheepCloudFarmIdentity(farmID: farm.id, generation: generation) {
                self.identity = current
            }
            errorMessage = "牧场名称已被其他设备修改，请核对最新云端名称后重新保存。"
        } catch {
            // Keep the request ID after an uncertain transport result.
            errorMessage = "暂时无法确认保存结果，请恢复网络后重试；同一请求不会重复改名。"
        }
    }
}
