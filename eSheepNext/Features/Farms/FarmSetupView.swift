import SwiftData
import SwiftUI

struct FarmSetupView: View {
    @Environment(AppSession.self) private var session

    let account: AccountProfile
    @State private var isMigrationPresented = false

    var body: some View {
        ZStack {
            AppTheme.pageBackground.ignoresSafeArea()

            ContentUnavailableView {
                Label("创建第一个牧场", systemImage: "building.2")
            } description: {
                Text("账户 \(account.displayName) 已就绪。创建牧场后即可独立记录羊只、圈舍、投喂和繁殖数据。")
            } actions: {
                Button("新建牧场") {
                    session.isCreateFarmPresented = true
                }
                .buttonStyle(.glassProminent)

                Button("加入牧场") {
                    session.isJoinFarmPresented = true
                }
                .buttonStyle(.glass)

                Button("从 eSheep+ 导入") {
                    isMigrationPresented = true
                }
                .buttonStyle(.glass)

                Text("导入会先检查并预览全部数据；确认后再创建牧场，联网时会自动同步。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                AccountSignOutButton()
            }
        }
        .sheet(isPresented: $isMigrationPresented) {
            NavigationStack {
                MigrationWorkspaceView()
            }
        }
    }
}

struct CreateFarmSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @Environment(SubscriptionService.self) private var subscription

    let account: AccountProfile

    @State private var name = ""
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("牧场信息") {
                    TextField("牧场名称", text: $name)
                        .focused($isNameFocused)
                        .textInputAutocapitalization(.never)
                }

                Section {
                    Text("创建后，你将成为该牧场的牧场主。账号准备完成后即可邀请成员协作。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新建牧场")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        closeSheet()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        createFarm()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                isNameFocused = true
            }
            .alert("无法创建牧场", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func createFarm() {
        do {
            try session.createFarm(
                named: name,
                account: account,
                entitlement: subscription.entitlement,
                context: modelContext
            )
            closeSheet()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func closeSheet() {
        session.isCreateFarmPresented = false
        dismiss()
    }
}
