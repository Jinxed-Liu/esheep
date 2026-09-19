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
    case legacyAccountClaimRequired

    var errorDescription: String? {
        switch self {
        case .passwordMismatch: "两次输入的密码不一致。"
        case .legacyAccountClaimRequired:
            "Apple 身份已经验证，但云端账号尚未关联原有账户。本机牧场没有被改写，请先完成旧账号认领后再试。"
        }
    }
}

struct WelcomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @Query private var accounts: [AccountProfile]
    @Query private var farms: [FarmRecord]

    let reauthenticationRequired: Bool

    @State private var connectionCheck = LoginConnectionCheck()
    @State private var credentialMode: WelcomeCredentialMode = .signIn
    @State private var username = ""
    @State private var email = ""
    @State private var emailVerificationCode = ""
    @State private var emailVerificationID: String?
    @State private var verificationCooldown = 0
    @State private var isSendingVerification = false
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var displayName = ""
    @State private var errorMessage: String?
    @State private var rawNonce = AppleIdentityActor.makeNonce()
    @State private var isBindingAccount = false
    @State private var selectedLegalDocument: LegalDocument?
    @State private var hasAcceptedTermsAndPrivacy = false
    @State private var hasAcceptedCrossBorder = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case username
        case email
        case verificationCode
        case password
        case confirmation
        case displayName
    }

    init(reauthenticationRequired: Bool = false) {
        self.reauthenticationRequired = reauthenticationRequired
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassEffectContainer(spacing: 18) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(.rect(cornerRadius: 21, style: .continuous))
                        .shadow(color: AppTheme.brand.opacity(0.22), radius: 12, y: 6)

                    VStack(spacing: 8) {
                        Text("eSheep+").font(.largeTitle.bold())
                        Text(reauthenticationRequired ? LocalizedStringKey("请重新登录账号") : LocalizedStringKey("新一代牧场管理"))
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = connectionCheck.message {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button("重试连接") { Task { await connectionCheck.check() } }
                            Button("系统设置") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        }
                        .font(.footnote)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let notice = session.authenticationNotice {
                    Label(LocalizedStringKey(notice), systemImage: "person.crop.circle.badge.checkmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                }

                VStack(spacing: 12) {
                    Picker("登录方式", selection: $credentialMode) {
                        ForEach(WelcomeCredentialMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.title)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if credentialMode == .signIn || AccountIdentityClients.activeProvider == .cloudBaseLegacy {
                        credentialFieldLabel(AccountIdentityClients.activeProvider == .supabase ? "邮箱" : "账号名")
                        TextField(
                            AccountIdentityClients.activeProvider == .supabase ? "name@example.com" : "例如 sheepowner01",
                            text: $username
                        )
                            .textContentType(AccountIdentityClients.activeProvider == .supabase ? .emailAddress : .username)
                            .keyboardType(AccountIdentityClients.activeProvider == .supabase ? .emailAddress : .default)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .username)
                            .textFieldStyle(.roundedBorder)
                    }

                    if credentialMode == .register {
                        credentialFieldLabel("邮箱")
                        TextField(
                            AccountIdentityClients.activeProvider == .supabase
                                ? "用于接收验证邮件"
                                : "用于接收 6 位注册验证码",
                            text: $email
                        )
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .email)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: email) { _, _ in emailVerificationID = nil }

                        if AccountIdentityClients.activeProvider == .cloudBaseLegacy {
                            credentialFieldLabel("邮箱验证码")
                            HStack(spacing: 10) {
                                TextField("6 位数字", text: $emailVerificationCode)
                                    .textContentType(.oneTimeCode)
                                    .keyboardType(.numberPad)
                                    .focused($focusedField, equals: .verificationCode)
                                    .textFieldStyle(.roundedBorder)
                                Button(verificationCooldown > 0 ? LocalizedStringKey("\(verificationCooldown) 秒") : LocalizedStringKey("发送验证码"), action: sendEmailVerification)
                                    .buttonStyle(.bordered)
                                    .disabled(isSendingVerification || verificationCooldown > 0 || !emailLooksValid || !identityIsConfigured)
                            }
                        }

                        credentialFieldLabel("显示名称")
                        TextField("例如 吉昊羊场", text: $displayName)
                            .textContentType(.name)
                            .focused($focusedField, equals: .displayName)
                            .textFieldStyle(.roundedBorder)
                    }

                    credentialFieldLabel("密码")
                    SecureField(credentialMode == .signIn ? "请输入密码" : "至少 10 位，必须包含文字和数字", text: $password)
                        .textContentType(credentialMode == .register ? .newPassword : .password)
                        .focused($focusedField, equals: .password)
                        .textFieldStyle(.roundedBorder)

                    if credentialMode == .register {
                        credentialFieldLabel("确认密码")
                        SecureField("再次输入相同密码", text: $passwordConfirmation)
                            .textContentType(.newPassword)
                            .focused($focusedField, equals: .confirmation)
                            .textFieldStyle(.roundedBorder)
                        Text(AccountIdentityClients.activeProvider == .supabase
                             ? "密码至少 10 位并包含文字和数字。注册后请按验证邮件完成邮箱验证。"
                             : "账号名为 5 至 24 位，以字母或数字开头，可使用字母、数字和 -_.:+@；密码至少 10 位并包含文字和数字。验证码 10 分钟内有效。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(action: submitPasswordAuthentication) {
                        Text(credentialMode == .signIn ? "登录" : (AccountIdentityClients.activeProvider == .supabase ? "注册并发送验证邮件" : "注册并登录"))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            isBindingAccount ||
                                !passwordFormIsReady ||
                                !identityIsConfigured ||
                                !hasRequiredLegalConsent
                        )

                    if !hasRequiredLegalConsent {
                        Text("请先在下方分别勾选必需的同意项。").font(.caption).foregroundStyle(.secondary)
                    }
                    if !identityIsConfigured {
                        Text("eSheep+ 云账号服务尚未配置，暂时无法注册或登录。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(18)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))

                HStack(spacing: 12) {
                    Rectangle().fill(.separator).frame(height: 1)
                    Text("或").font(.footnote).foregroundStyle(.secondary)
                    Rectangle().fill(.separator).frame(height: 1)
                }

                SignInWithAppleButton(.continue) { request in
                    // A returning account only needs the stable Apple subject
                    // and ID token. The name is optional and can be updated
                    // separately when Apple happens to return it.
                    request.requestedScopes = []
                    request.nonce = AppleIdentityActor.hashedNonce(rawNonce)
                } onCompletion: { result in
                    handleAppleAuthorization(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52)
                .clipShape(.rect(cornerRadius: 14))
                .disabled(isBindingAccount || !identityIsConfigured || !hasRequiredLegalConsent)

                Text("使用同一 Apple 账户，可在不同设备登录同一牧场账号。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)

                if isBindingAccount {
                    ProgressView(credentialMode == .register ? "正在创建账号" : "正在验证账号")
                        .font(.footnote)
                }

                legalConsentCard

            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .task { await connectionCheck.check() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, connectionCheck.message != nil {
                Task { await connectionCheck.check() }
            }
        }
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
            Text(LocalizedStringKey(errorMessage ?? ""))
        }
    }

    private var passwordFormIsReady: Bool {
        let hasCredential = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
        if credentialMode == .signIn { return hasCredential }
        if AccountIdentityClients.activeProvider == .supabase {
            return emailLooksValid
                && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !password.isEmpty
                && !passwordConfirmation.isEmpty
        }
        return hasCredential
            && emailLooksValid
            && emailVerificationID != nil
            && emailVerificationCode.count == 6
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !passwordConfirmation.isEmpty
    }

    private var hasRequiredLegalConsent: Bool {
        hasAcceptedTermsAndPrivacy && hasAcceptedCrossBorder
    }

    private var legalConsentCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("我已阅读并同意服务条款和隐私政策", isOn: $hasAcceptedTermsAndPrivacy)
                .toggleStyle(ConsentCheckboxStyle())
            HStack(spacing: 12) {
                Button("《服务条款》") { selectedLegalDocument = .terms }
                Button("《隐私政策》") { selectedLegalDocument = .privacy }
            }
            .foregroundStyle(AppTheme.brand)
            .padding(.leading, 32)

            Toggle("我单独同意必要的境外云处理", isOn: $hasAcceptedCrossBorder)
                .toggleStyle(ConsentCheckboxStyle())
            Button("《境外云处理告知》 · 接收方、用途与撤回方式") {
                selectedLegalDocument = .crossBorder
            }
            .foregroundStyle(AppTheme.brand)
            .padding(.leading, 32)
            Text("用于账号与云同步；可选 AI 会另行征求同意。")
                .foregroundStyle(.secondary)
                .padding(.leading, 32)
        }
        .font(.caption)
        .buttonStyle(.plain)
        .tint(AppTheme.brand)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identityIsConfigured: Bool {
        ESheepCloudAvailability.isConfigured || IdentityWorkerConfiguration.baseURL != nil
    }

    private var emailLooksValid: Bool {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains("@") && value.split(separator: "@").last?.contains(".") == true
    }

    private func sendEmailVerification() {
        let submittedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isSendingVerification = true
        Task {
            defer { isSendingVerification = false }
            do {
                let result = try await IdentityWorkerClient.shared.requestEmailVerification(email: submittedEmail)
                emailVerificationID = result.verificationID
                verificationCooldown = 60
                while verificationCooldown > 0 {
                    try await Task.sleep(for: .seconds(1))
                    verificationCooldown -= 1
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func submitPasswordAuthentication() {
        guard hasRequiredLegalConsent else {
            errorMessage = "请先分别阅读并同意服务条款/隐私政策和必要的境外云处理。"
            return
        }
        let mode = credentialMode
        let submittedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let submittedVerificationCode = emailVerificationCode
        let submittedVerificationID = emailVerificationID
        let submittedPassword = password
        let submittedConfirmation = passwordConfirmation
        let submittedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        isBindingAccount = true
        Task {
            defer { isBindingAccount = false }
            do {
                let response: WorkerSessionResponse
                if AccountIdentityClients.activeProvider == .supabase {
                    let identityClient = try AccountIdentityClients.active()
                    if mode == .register {
                        guard submittedPassword == submittedConfirmation else { throw WelcomeAuthError.passwordMismatch }
                        let registration = try await identityClient.register(
                            email: submittedEmail,
                            password: submittedPassword,
                            displayName: submittedDisplayName
                        )
                        switch registration {
                        case .authenticated(let authenticatedResponse):
                            response = authenticatedResponse
                        case .verificationRequired(let verificationEmail):
                            credentialMode = .signIn
                            username = verificationEmail
                            password = ""
                            passwordConfirmation = ""
                            session.authenticationNotice =
                                "验证邮件已发送至 \(verificationEmail)。完成邮箱验证后，请返回此处手动登录。"
                            return
                        }
                    } else {
                        response = try await identityClient.authenticate(
                            email: submittedUsername,
                            password: submittedPassword
                        )
                    }
                } else if mode == .register {
                    guard submittedPassword == submittedConfirmation else { throw WelcomeAuthError.passwordMismatch }
                    guard let submittedVerificationID else { return }
                    response = try await IdentityWorkerClient.shared.register(
                        email: submittedEmail,
                        verificationID: submittedVerificationID,
                        verificationCode: submittedVerificationCode,
                        username: submittedUsername,
                        password: submittedPassword,
                        displayName: submittedDisplayName
                    )
                } else {
                    response = try await IdentityWorkerClient.shared.authenticate(username: submittedUsername, password: submittedPassword)
                }
                let identityClient = try AccountIdentityClients.active()
                let consentReceipt = LegalConsentReceipt()
                try await identityClient.recordLegalConsent(consentReceipt)
                let accountProfileID = try upsertPasswordAccount(
                    from: response,
                    consentReceipt: consentReceipt
                )
                try LegalConsentStore.save(consentReceipt, for: response.accountID)
                if AccountIdentityClients.activeProvider == .supabase {
                    _ = try await DeviceIdentityActor.shared.registerWithActiveAccountProvider()
                }
                session.authenticationDidSucceed(accountProfileID: accountProfileID)
                try? SecureAccountStore.removeAppleUserIdentifier()
                password = ""
                passwordConfirmation = ""
                emailVerificationCode = ""
                emailVerificationID = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func credentialFieldLabel(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handleAppleAuthorization(_ result: Result<ASAuthorization, Error>) {
        guard hasRequiredLegalConsent else {
            errorMessage = "请先分别阅读并同意服务条款/隐私政策和必要的境外云处理。"
            return
        }
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
                    let workerSession = try await AppleIdentityActor.shared.bind(payload)
                    let consentReceipt = LegalConsentReceipt()
                    try await AccountIdentityClients.active().recordLegalConsent(consentReceipt)
                    let accountProfileID = try upsertAppleAccount(
                        from: credential,
                        workerSession: workerSession,
                        consentReceipt: consentReceipt
                    )
                    try LegalConsentStore.save(consentReceipt, for: workerSession.accountID)
                    if AccountIdentityClients.activeProvider == .supabase {
                        _ = try await DeviceIdentityActor.shared.registerWithActiveAccountProvider()
                    }
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
    private func upsertPasswordAccount(
        from response: WorkerSessionResponse,
        consentReceipt: LegalConsentReceipt
    ) throws -> UUID {
        if let existing = accounts.first(where: { $0.serverAccountID == response.accountID }) {
            try prepareForDifferentAccount(activating: existing.id)
            existing.displayName = response.displayName ?? existing.displayName
            existing.serverBindingStateRaw = ServerBindingState.verified.rawValue
            existing.authenticationMethodRawValue = AccountAuthenticationMethod.password.rawValue
            existing.acceptedTermsVersion = consentReceipt.termsVersion
            existing.acceptedPrivacyVersion = consentReceipt.privacyVersion
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
        account.acceptedTermsVersion = consentReceipt.termsVersion
        account.acceptedPrivacyVersion = consentReceipt.privacyVersion
        try prepareForDifferentAccount(activating: account.id)
        modelContext.insert(account)
        try modelContext.save()
        return account.id
    }

    @MainActor
    private func upsertAppleAccount(
        from credential: ASAuthorizationAppleIDCredential,
        workerSession: WorkerSessionResponse,
        consentReceipt: LegalConsentReceipt
    ) throws -> UUID {
        let appleID = credential.user
        let appleSubjectHash = AppleIdentityHash.value(for: appleID)
        if let existing = accounts.first(where: { $0.appleSubjectHash == appleSubjectHash }) {
            if let legacyAppAccountID = existing.serverAccountID,
               legacyAppAccountID != workerSession.accountID,
               farms.contains(where: {
                   $0.ownerAccountID == legacyAppAccountID &&
                       $0.deletedAt == nil
               }) {
                throw WelcomeAuthError.legacyAccountClaimRequired
            }
            try prepareForDifferentAccount(activating: existing.id)
            try SecureAccountStore.saveAppleUserIdentifier(appleID)
            existing.serverAccountID = workerSession.accountID
            existing.serverBindingStateRaw = ServerBindingState.verified.rawValue
            existing.authenticationMethodRawValue = AccountAuthenticationMethod.apple.rawValue
            existing.acceptedTermsVersion = consentReceipt.termsVersion
            existing.acceptedPrivacyVersion = consentReceipt.privacyVersion
            if let name = workerSession.displayName, !name.isEmpty { existing.displayName = name }
            existing.updatedAt = .now
            try modelContext.save()
            return existing.id
        }
        let formatter = PersonNameComponentsFormatter()
        let formattedName = credential.fullName.map(formatter.string(from:)) ?? "Apple 账户"
        let account = AccountProfile(
            appleUserIdentifier: appleID,
            displayName: workerSession.displayName ?? (formattedName.isEmpty ? "Apple 账户" : formattedName),
            serverBindingStateRaw: ServerBindingState.verified.rawValue,
            authenticationMethod: .apple
        )
        account.serverAccountID = workerSession.accountID
        account.acceptedTermsVersion = consentReceipt.termsVersion
        account.acceptedPrivacyVersion = consentReceipt.privacyVersion
        try prepareForDifferentAccount(activating: account.id)
        try SecureAccountStore.saveAppleUserIdentifier(appleID)
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
