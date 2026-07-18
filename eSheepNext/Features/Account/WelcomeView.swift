import AuthenticationServices
import SwiftData
import SwiftUI

private enum WelcomeCredentialMode: String, CaseIterable, Identifiable {
    case signIn
    case register

    var id: String { rawValue }
    var title: String { self == .signIn ? "账号登录" : "注册账号" }
}

private enum WelcomeAuthError: LocalizedError {
    case passwordMismatch

    var errorDescription: String? {
        switch self {
        case .passwordMismatch: "两次输入的密码不一致。"
        }
    }
}

struct WelcomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @Query private var accounts: [AccountProfile]
    @Query private var farms: [FarmRecord]

    let reauthenticationRequired: Bool

    @State private var credentialMode: WelcomeCredentialMode = .signIn
    @State private var username = ""
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var displayName = ""
    @State private var errorMessage: String?
    @State private var deferredAppleBrokerMessage: String?
    @State private var rawNonce = AppleIdentityActor.makeNonce()
    @State private var isBindingAccount = false
    @State private var selectedLegalDocument: LegalDocument?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case username
        case password
        case confirmation
        case displayName
    }

    init(reauthenticationRequired: Bool = false) {
        self.reauthenticationRequired = reauthenticationRequired
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                GlassEffectContainer(spacing: 18) {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(AppTheme.brand)
                        .frame(width: 92, height: 92)
                        .glassEffect(.regular, in: .circle)

                    VStack(spacing: 8) {
                        Text("eSheep+").font(.largeTitle.bold())
                        Text(reauthenticationRequired ? "请重新登录账号" : "新一代牧场管理")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                if let notice = session.authenticationNotice {
                    Label(notice, systemImage: "person.crop.circle.badge.checkmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                }

                if let deferredAppleBrokerMessage {
                    Label(deferredAppleBrokerMessage, systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                }

                VStack(spacing: 16) {
                    Picker("登录方式", selection: $credentialMode) {
                        ForEach(WelcomeCredentialMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    credentialFieldLabel("账号名")
                    TextField("例如 sheepowner01", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                        .textFieldStyle(.roundedBorder)

                    if credentialMode == .register {
                        credentialFieldLabel("显示名称")
                        TextField("例如 吉昊羊场", text: $displayName)
                            .textContentType(.name)
                            .focused($focusedField, equals: .displayName)
                            .textFieldStyle(.roundedBorder)
                    }

                    credentialFieldLabel("密码")
                    SecureField("至少 10 位，必须包含文字和数字", text: $password)
                        .textContentType(credentialMode == .register ? .newPassword : .password)
                        .focused($focusedField, equals: .password)
                        .textFieldStyle(.roundedBorder)

                    if credentialMode == .register {
                        credentialFieldLabel("确认密码")
                        SecureField("再次输入相同密码", text: $passwordConfirmation)
                            .textContentType(.newPassword)
                            .focused($focusedField, equals: .confirmation)
                            .textFieldStyle(.roundedBorder)
                        Text("账号名为 3 至 32 位；密码为 10 至 128 位，并同时包含文字和数字。Android 端可使用同一账号登录。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(credentialMode == .signIn ? "登录" : "注册并登录", action: submitPasswordAuthentication)
                        .buttonStyle(.glassProminent)
                        .frame(maxWidth: .infinity)
                        .disabled(isBindingAccount || !passwordFormIsReady || IdentityWorkerConfiguration.baseURL == nil)

                    if IdentityWorkerConfiguration.baseURL == nil {
                        Text("账号注册与密码登录需要部署身份服务。Apple 登录仍可建立本机工作空间。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(18)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))

                HStack(spacing: 12) {
                    Rectangle().fill(.separator).frame(height: 1)
                    Text("或").font(.footnote).foregroundStyle(.secondary)
                    Rectangle().fill(.separator).frame(height: 1)
                }

                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName]
                    request.nonce = AppleIdentityActor.hashedNonce(rawNonce)
                } onCompletion: { result in
                    handleAppleAuthorization(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52)
                .clipShape(.rect(cornerRadius: 14))
                .disabled(isBindingAccount)

                Text("Apple 登录使用系统当前提供的 Apple 账户。App 无法读取账号列表，也不能伪造账号选择器；双账号协作测试应让两台设备分别登录不同的系统 Apple 账户。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)

                if isBindingAccount {
                    ProgressView(credentialMode == .register ? "正在创建账号" : "正在验证账号")
                        .font(.footnote)
                }

                VStack(spacing: 8) {
                    Text("继续表示你已阅读并同意以下说明：")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 14) {
                        ForEach(LegalDocument.allCases) { document in
                            Button(document.title) { selectedLegalDocument = document }
                                .font(.footnote)
                        }
                    }
                }
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .sheet(item: $selectedLegalDocument) { document in
            NavigationStack {
                LegalDocumentView(document: document)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { selectedLegalDocument = nil }
                        }
                    }
            }
        }
        .alert("登录未完成", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var passwordFormIsReady: Bool {
        let hasCredential = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
        if credentialMode == .signIn { return hasCredential }
        return hasCredential && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !passwordConfirmation.isEmpty
    }

    private func submitPasswordAuthentication() {
        let mode = credentialMode
        let submittedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedPassword = password
        let submittedConfirmation = passwordConfirmation
        let submittedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        isBindingAccount = true
        Task {
            defer { isBindingAccount = false }
            do {
                let response: WorkerSessionResponse
                if mode == .register {
                    guard submittedPassword == submittedConfirmation else { throw WelcomeAuthError.passwordMismatch }
                    response = try await IdentityWorkerClient.shared.register(
                        username: submittedUsername,
                        password: submittedPassword,
                        displayName: submittedDisplayName
                    )
                } else {
                    response = try await IdentityWorkerClient.shared.authenticate(username: submittedUsername, password: submittedPassword)
                }
                let accountProfileID = try upsertPasswordAccount(from: response)
                session.authenticationDidSucceed(accountProfileID: accountProfileID)
                try? SecureAccountStore.removeAppleUserIdentifier()
                password = ""
                passwordConfirmation = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func credentialFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handleAppleAuthorization(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "未获得可用的 Apple 账户凭据。"
                return
            }
            let nonce = rawNonce
            isBindingAccount = true
            Task {
                defer {
                    isBindingAccount = false
                    rawNonce = AppleIdentityActor.makeNonce()
                }
                do {
                    let payload = try AppleIdentityActor.payload(from: credential, rawNonce: nonce)
                    let workerSession: WorkerSessionResponse?
                    if IdentityWorkerConfiguration.baseURL == nil {
                        workerSession = nil
                    } else {
                        do {
                            workerSession = try await AppleIdentityActor.shared.bind(payload)
                        } catch let error as IdentityWorkerError where error.canDeferAppleBroker {
                            workerSession = nil
                            deferredAppleBrokerMessage = "Apple 账户已完成系统认证，但当前无法连接身份服务。已进入本机工作空间；云端协作将在身份服务恢复后可用。"
                        }
                    }
                    let accountProfileID = try upsertAppleAccount(from: credential, workerSession: workerSession)
                    session.authenticationDidSucceed(accountProfileID: accountProfileID)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func upsertPasswordAccount(from response: WorkerSessionResponse) throws -> UUID {
        if let existing = accounts.first(where: { $0.serverAccountID == response.accountID }) {
            try prepareForDifferentAccount(activating: existing.id)
            existing.displayName = response.displayName ?? existing.displayName
            existing.serverBindingStateRaw = ServerBindingState.verified.rawValue
            existing.authenticationMethodRawValue = AccountAuthenticationMethod.password.rawValue
            existing.updatedAt = .now
            try modelContext.save()
            return existing.id
        }

        let account = AccountProfile(
            appleUserIdentifier: "password:\(response.accountID.uuidString.lowercased())",
            displayName: response.displayName ?? username,
            serverBindingStateRaw: ServerBindingState.verified.rawValue,
            authenticationMethod: .password
        )
        account.serverAccountID = response.accountID
        try prepareForDifferentAccount(activating: account.id)
        modelContext.insert(account)
        try modelContext.save()
        return account.id
    }

    @MainActor
    private func upsertAppleAccount(from credential: ASAuthorizationAppleIDCredential, workerSession: WorkerSessionResponse?) throws -> UUID {
        let appleID = credential.user
        let appleSubjectHash = AppleIdentityHash.value(for: appleID)
        if let existing = accounts.first(where: { $0.appleSubjectHash == appleSubjectHash }) {
            try prepareForDifferentAccount(activating: existing.id)
            try SecureAccountStore.saveAppleUserIdentifier(appleID)
            existing.serverAccountID = workerSession?.accountID ?? existing.serverAccountID
            existing.serverBindingStateRaw = workerSession == nil ? ServerBindingState.pendingBroker.rawValue : ServerBindingState.verified.rawValue
            existing.authenticationMethodRawValue = AccountAuthenticationMethod.apple.rawValue
            if let name = workerSession?.displayName, !name.isEmpty { existing.displayName = name }
            existing.updatedAt = .now
            try modelContext.save()
            return existing.id
        }
        let formatter = PersonNameComponentsFormatter()
        let formattedName = credential.fullName.map(formatter.string(from:)) ?? "Apple 账户"
        let account = AccountProfile(
            appleUserIdentifier: appleID,
            displayName: workerSession?.displayName ?? (formattedName.isEmpty ? "Apple 账户" : formattedName),
            serverBindingStateRaw: workerSession == nil ? ServerBindingState.pendingBroker.rawValue : ServerBindingState.verified.rawValue,
            authenticationMethod: .apple
        )
        account.serverAccountID = workerSession?.accountID
        try prepareForDifferentAccount(activating: account.id)
        try SecureAccountStore.saveAppleUserIdentifier(appleID)
        if workerSession == nil {
            try SecureAccountStore.remove(account: "worker-access-token")
            try SecureAccountStore.remove(account: "worker-refresh-token")
        }
        modelContext.insert(account)
        try modelContext.save()
        return account.id
    }

    @MainActor
    private func prepareForDifferentAccount(activating accountProfileID: UUID) throws {
        guard session.activeAccountProfileID != accountProfileID else { return }
        for key in ["device-id", "device-secure-enclave-key", "device-software-key"] {
            try SecureAccountStore.remove(account: key)
        }
        try SecureAccountStore.removeAppleUserIdentifier()
    }
}
