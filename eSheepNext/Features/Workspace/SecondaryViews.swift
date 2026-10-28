import ESMotion
import SwiftData
import SwiftUI

struct FarmInsightsView: View {
    let account: AccountProfile
    let farm: FarmRecord
    @Binding var assistantFarmID: UUID?
    @State private var suggestedQuestion: String?
    @Namespace private var assistantTransition

    var body: some View {
        Group {
            if farmContext.capabilities.allows(.viewAnalytics) {
                FarmAnalysisCenterView(
                    account: account,
                    farm: farm,
                    assistantTransition: assistantTransition,
                    assistantTransitionID: assistantTransitionID,
                    assistantTransitionSpec: assistantTransitionSpec
                ) { question in
                    presentAssistant(question: question)
                }
            } else {
                ContentUnavailableView {
                    Label("无法查看牧场分析", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("当前牧场角色没有分析权限，但仍可使用 AI 助手查询获准读取的数据。")
                } actions: {
                    Button("与 AI 助手聊天") { presentAssistant() }
                        .buttonStyle(.borderedProminent)
                        .motionTransitionSource(
                            id: assistantTransitionID,
                            in: assistantTransition,
                            spec: assistantTransitionSpec,
                            background: AppTheme.pageBackground
                        )
                }
            }
        }
        .navigationDestination(isPresented: assistantPresentation) {
            FarmInsightConversationListView(account: account, farm: farm, initialPrompt: suggestedQuestion)
                .equatable()
                .id(farm.id)
                .motionTransitionDestination(
                    id: assistantTransitionID,
                    in: assistantTransition,
                    spec: assistantTransitionSpec
                )
        }
    }

    private var assistantTransitionID: MotionTransitionID {
        MotionTransitionID("farm-assistant-\(farm.id.uuidString)")
    }

    private var assistantTransitionSpec: MotionTransitionSpec {
        MotionTransitionSpec(
            preset: .card,
            cornerRadius: 28
        )
    }

    private func presentAssistant(question: String? = nil) {
        guard assistantFarmID != farm.id else { return }
        suggestedQuestion = question
        assistantFarmID = farm.id
    }

    private var assistantPresentation: Binding<Bool> {
        Binding(
            get: {
                assistantFarmID == farm.id
            },
            set: { isPresented in
                if isPresented {
                    assistantFarmID = farm.id
                } else if assistantFarmID == farm.id {
                    assistantFarmID = nil
                    suggestedQuestion = nil
                }
            }
        )
    }

    private var farmContext: FarmContext {
        FarmContext(
            accountID: account.effectiveAccountID,
            farmID: farm.id,
            role: farm.role
        )
    }
}

struct FarmSettingsView: View {
    let account: AccountProfile
    let farm: FarmRecord

    var body: some View {
        SettingsHomeView(account: account, farm: farm)
    }
}

@MainActor
struct AccountDisplayNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile

    @State private var displayName: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    init(account: AccountProfile) {
        self.account = account
        _displayName = State(initialValue: account.displayName)
    }

    private var normalizedName: String {
        displayName.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !isSaving && !normalizedName.isEmpty && normalizedName.count <= 40 && normalizedName != account.displayName
    }

    var body: some View {
        Form {
            Section("账户名称") {
                TextField("显示名称", text: $displayName)
                    .textContentType(.name)
                    .focused($isNameFocused)
                    .submitLabel(.done)
                    .onSubmit { if canSave { save() } }
                Text("名称会同步到你的 eSheep+ 账户，并显示给同一牧场的协作成员。最多 40 个字符。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("修改名称")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("保存", action: save)
                        .disabled(!canSave)
                }
            }
        }
        .alert("无法修改名称", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(errorMessage ?? "未知错误"))
        }
        .onAppear { isNameFocused = true }
    }

    private func save() {
        let submittedName = normalizedName
        guard !submittedName.isEmpty, submittedName.count <= 40 else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                account.displayName = try await AccountIdentityClients.active()
                    .updateDisplayName(submittedName)
                account.updatedAt = .now
                try modelContext.save()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
