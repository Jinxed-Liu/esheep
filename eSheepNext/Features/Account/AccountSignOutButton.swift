import SwiftUI

struct AccountSignOutButton: View {
    @Environment(AppSession.self) private var session

    @State private var isConfirming = false
    @State private var isSigningOut = false
    @State private var errorMessage: String?

    var body: some View {
        Button("退出登录", role: .destructive) {
            isConfirming = true
        }
        .disabled(isSigningOut)
        .confirmationDialog("确认退出登录", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                signOut()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后保留本机牧场缓存与未同步记录。登录其他账号时，旧缓存会保留但不会显示给新账号。")
        }
        .alert("无法完成退出登录", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func signOut() {
        isSigningOut = true
        Task { @MainActor in
            defer { isSigningOut = false }
            do {
                let result = try await IdentityWorkerClient.shared.signOut()
                session.authenticationDidSignOut(warning: result.warningMessage)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
