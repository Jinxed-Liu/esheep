import SwiftData
import SwiftUI
import WebKit

struct InsightAssistantSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord

    @State private var controller: InsightConversationController
    @State private var apiKey = ""
    @State private var savedCredentialMask: String?
    @State private var isRevealed = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isDeleteConfirmationPresented = false
    @State private var insightDevices: [WorkerInsightDeviceList.Device] = []
    @State private var recoveryCode = ""
    @State private var recoveryInput = ""
    @State private var isLoadingSecurity = false
    @State private var securityStatusMessage: String?
    @State private var currentDeviceID: UUID?
    @State private var devicePendingRevocation: WorkerInsightDeviceList.Device?
    @State private var retainsSentVoiceAudio: Bool
    @State private var officialUsage: MiMoOfficialUsageSnapshot?
    @State private var officialUsageMessage: String?
    @State private var isLoadingOfficialUsage = false
    @State private var isOfficialLoginPresented = false

    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account
        self.farm = farm
        _controller = State(
            initialValue: InsightConversationController(account: account, farm: farm)
        )
        _retainsSentVoiceAudio = State(
            initialValue: InsightVoicePrivacyPreference.retainsSentAudio(
                for: account.effectiveAccountID
            )
        )
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("服务商", value: "MiMo")
                LabeledContent("文字与工具", value: "mimo-v2.5-pro")
                LabeledContent("图片与语音", value: "mimo-v2.5")
            } header: {
                Text("模型")
            } footer: {
                Text("模型由输入类型自动切换，不开放自定义模型或第三方地址。")
            }

            Section {
                LabeledContent("窗口上限", value: "约 512K")
                LabeledContent("压缩后目标", value: "约 384K")
            } header: {
                Text("上下文窗口")
            } footer: {
                Text("AI 对话页顶部圆环显示当前会话的上下文使用比例。用量由 App 在本地保守估算；达到约 512K 时自动压缩较早内容并保留最近对话，聊天中会显示一次压缩提示。")
            }

            Section {
                if let officialUsage {
                    LabeledContent(
                        "账户余额",
                        value: officialCurrency(
                            officialUsage.balance,
                            code: officialUsage.currency
                        )
                    )
                    if let planCode = officialUsage.planCode {
                        LabeledContent("Token Plan", value: planCode)
                    }
                    if let used = officialUsage.tokenUsed,
                       let limit = officialUsage.tokenLimit {
                        LabeledContent("已用 Token", value: compactInteger(used))
                        LabeledContent(
                            "剩余 Token",
                            value: compactInteger(max(0, limit - used))
                        )
                        LabeledContent("套餐总量", value: compactInteger(limit))
                        if let fraction = officialUsage.tokenFraction {
                            ProgressView(value: fraction)
                                .tint(fraction >= 0.9 ? .orange : AppTheme.brand)
                        }
                    }
                    if let periodEnd = officialUsage.planPeriodEnd {
                        LabeledContent("本期结束") {
                            Text(periodEnd, format: .dateTime.year().month().day())
                        }
                    }
                    LabeledContent("官方更新") {
                        Text(
                            officialUsage.updatedAt,
                            format: .dateTime.hour().minute().second()
                        )
                    }
                } else {
                    Text(officialUsageMessage ?? "登录 MiMo 官方账户后可读取真实余额和 Token Plan 用量。")
                        .foregroundStyle(.secondary)
                }

                Button {
                    refreshOfficialUsage()
                } label: {
                    if isLoadingOfficialUsage {
                        HStack {
                            ProgressView()
                            Text("正在查询官方额度")
                        }
                    } else {
                        Text(officialUsage == nil ? "查询官方额度" : "刷新官方额度")
                    }
                }
                .disabled(isLoadingOfficialUsage)

                Button("登录 MiMo 官方账户") {
                    isOfficialLoginPresented = true
                }
            } header: {
                Text("MiMo 官方额度")
            } footer: {
                Text("数据直接读取 MiMo 官方控制台。网页登录会话与 API Key 分开保存；App 不会读取或保存你的小米账号密码。")
            }

            Section {
                if let masked = savedCredentialMask {
                    LabeledContent("当前 Key", value: masked)
                }

                HStack {
                    Group {
                        if isRevealed {
                            TextField("sk- 或 tp- 开头", text: $apiKey)
                        } else {
                            SecureField("sk- 或 tp- 开头", text: $apiKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(isRevealed ? "隐藏 API Key" : "显示 API Key")
                }

                PasteButton(payloadType: String.self) { values in
                    apiKey = values.first ?? ""
                }
                .labelStyle(.titleAndIcon)

                Button {
                    save()
                } label: {
                    if isSaving || controller.isTestingCredential {
                        HStack {
                            ProgressView()
                            Text("正在测试连接")
                        }
                    } else {
                        Text(savedCredentialMask == nil ? "测试连接并保存" : "测试连接并替换")
                    }
                }
                .disabled(
                    apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isSaving
                        || controller.isTestingCredential
                )

                if savedCredentialMask != nil {
                    Button("删除 API Key", role: .destructive) {
                        isDeleteConfirmationPresented = true
                    }
                }
            } header: {
                Text("MiMo API Key")
            } footer: {
                Text("sk- 使用标准地址，tp- 使用 Token Plan 地址。Key 通过连接测试后保存在本机钥匙串。")
            }

            Section("数据与隐私") {
                InsightAssistantPrivacyRow(
                    systemImage: "iphone.and.arrow.forward",
                    title: "请求直接发送",
                    detail: "模型请求由此 iPhone 直接发往 MiMo，eSheep 服务端不接触明文 Key。"
                )
                Toggle(isOn: $retainsSentVoiceAudio) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("在本机保留已发送语音")
                            Text("发送时直接提交 MiMo；用于回听的原始副本只保存在此 iPhone，不上传到 eSheep 云端或参与个人空间同步。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "waveform")
                            .foregroundStyle(AppTheme.brand)
                    }
                }
                .accessibilityHint("只影响之后发送的语音")
                .onChange(of: retainsSentVoiceAudio) { _, isEnabled in
                    InsightVoicePrivacyPreference.setRetainsSentAudio(
                        isEnabled,
                        for: account.effectiveAccountID
                    )
                }
                InsightAssistantPrivacyRow(
                    systemImage: "photo",
                    title: "图片先处理",
                    detail: "图片移除位置与 EXIF 信息并压缩后，才会提交模型或进入加密同步。"
                )
                InsightAssistantPrivacyRow(
                    systemImage: "chart.bar.doc.horizontal",
                    title: "牧场数据按需提供",
                    detail: "默认只发送当前问题和有限结果；敏感明细或扩展范围每次都需要单独授权。"
                )
            }

            Section {
                if IdentityWorkerConfiguration.baseURL == nil {
                    Text("账号服务未配置，洞察历史和 Key 仅保存在本机。")
                        .foregroundStyle(.secondary)
                } else if let securityStatusMessage {
                    Text("加密同步暂不可用：\(securityStatusMessage)\nMiMo Key 已安全保存在本机，不受影响。")
                        .foregroundStyle(.secondary)
                } else if insightDevices.isEmpty {
                    Text(isLoadingSecurity ? "正在读取设备…" : "暂无设备信息")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(insightDevices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.displayName)
                                Text(deviceStatus(device))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.status == "pending" {
                                Button("批准") {
                                    approve(device)
                                }
                            } else if device.status == "active",
                                      device.deviceID != currentDeviceID {
                                Button("撤销", role: .destructive) {
                                    devicePendingRevocation = device
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("加密同步设备")
            } footer: {
                Text("批准和撤销需要 Face ID / Touch ID。撤销会轮换个人主密钥；旧设备已离线缓存的内容无法远程抹除。")
            }

            Section("恢复码") {
                Button("生成并上传恢复包") {
                    generateRecovery()
                }

                if !recoveryCode.isEmpty {
                    Text(recoveryCode)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text("恢复码只显示在这里，请离线妥善保存。每个恢复包只能成功使用一次，恢复后请重新生成。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                SecureField("输入恢复码", text: $recoveryInput)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()

                Button("使用恢复码恢复") {
                    importRecovery()
                }
                .disabled(recoveryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("AI 助手")
        .navigationBarTitleDisplayMode(.inline)
        .alert("AI 助手设置", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "删除 MiMo API Key？",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                removeCredential()
            }
        } message: {
            Text("删除后助手不可用，历史会话仍保留。")
        }
        .confirmationDialog(
            "撤销这台设备？",
            isPresented: Binding(
                get: { devicePendingRevocation != nil },
                set: { if !$0 { devicePendingRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("撤销并轮换密钥", role: .destructive) {
                guard let device = devicePendingRevocation else { return }
                devicePendingRevocation = nil
                revoke(device)
            }
            Button("取消", role: .cancel) {
                devicePendingRevocation = nil
            }
        } message: {
            Text("撤销后会为其余设备轮换个人主密钥。已被该设备离线缓存的旧内容无法远程抹除。")
        }
        .sheet(isPresented: $isOfficialLoginPresented) {
            NavigationStack {
                MiMoOfficialLoginView {
                    isOfficialLoginPresented = false
                    refreshOfficialUsage()
                }
                .navigationTitle("登录 MiMo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") {
                            isOfficialLoginPresented = false
                        }
                    }
                }
            }
        }
        .task {
            await controller.connect(to: modelContext)
            await loadCredentialStatus()
            await loadSecurityDevices()
            await loadOfficialUsage(silent: true)
        }
    }

    private func refreshOfficialUsage() {
        guard !isLoadingOfficialUsage else { return }
        isLoadingOfficialUsage = true
        Task {
            await loadOfficialUsage(silent: false)
            isLoadingOfficialUsage = false
        }
    }

    private func loadOfficialUsage(silent: Bool) async {
        do {
            officialUsage = try await MiMoOfficialUsageService.shared.fetch()
            officialUsageMessage = nil
        } catch {
            officialUsage = nil
            let hasSession = await MiMoOfficialUsageService.shared.hasOfficialSession()
            if !silent || hasSession {
                officialUsageMessage = error.localizedDescription
            }
        }
    }

    private func officialCurrency(_ value: Decimal, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber)
            ?? "\(code) \(value)"
    }

    private func compactInteger(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private func save() {
        guard !isSaving, !controller.isTestingCredential else { return }
        let submittedKey = apiKey
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let credential = try await controller.saveCredential(submittedKey)
                savedCredentialMask = credential.maskedValue
                apiKey = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removeCredential() {
        Task {
            do {
                try await controller.removeCredential()
                apiKey = ""
                savedCredentialMask = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadCredentialStatus() async {
        do {
            savedCredentialMask = try await MiMoCredentialVault.shared
                .credential(for: account.effectiveAccountID)?
                .maskedValue
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSecurityDevices() async {
        guard IdentityWorkerConfiguration.baseURL != nil else { return }
        isLoadingSecurity = true
        securityStatusMessage = nil
        defer { isLoadingSecurity = false }
        do {
            currentDeviceID = try await InsightPersonalSyncActor.shared.currentDeviceID()
            insightDevices = try await IdentityWorkerClient.shared.insightDevices().devices
        } catch {
            insightDevices = []
            securityStatusMessage = error.localizedDescription
        }
    }

    private func revoke(_ device: WorkerInsightDeviceList.Device) {
        Task {
            do {
                try await InsightPersonalSyncActor.shared.revoke(
                    device: device,
                    accountID: account.effectiveAccountID,
                    context: modelContext
                )
                recoveryCode = ""
                await loadSecurityDevices()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deviceStatus(_ device: WorkerInsightDeviceList.Device) -> String {
        if device.deviceID == currentDeviceID, device.status == "active" {
            return "此设备 · 已授权"
        }
        switch device.status {
        case "active":
            return "已授权"
        case "pending":
            return "等待批准"
        default:
            return "已撤销"
        }
    }

    private func approve(_ device: WorkerInsightDeviceList.Device) {
        Task {
            do {
                try await InsightPersonalSyncActor.shared.approve(
                    device: device,
                    accountID: account.effectiveAccountID
                )
                await loadSecurityDevices()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func generateRecovery() {
        Task {
            do {
                let export = try await InsightPersonalSyncActor.shared.exportRecovery(
                    accountID: account.effectiveAccountID
                )
                recoveryCode = export.recoveryCode
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importRecovery() {
        Task {
            do {
                try await InsightPersonalSyncActor.shared.importRecovery(
                    code: recoveryInput,
                    accountID: account.effectiveAccountID,
                    context: modelContext
                )
                recoveryInput = ""
                recoveryCode = ""
                await loadSecurityDevices()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct InsightAssistantPrivacyRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.brand)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MiMoOfficialLoginView: UIViewRepresentable {
    let onAuthenticated: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuthenticated: onAuthenticated)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView
        let loginURL = URL(
            string: "https://platform.xiaomimimo.com/api/v1/genLoginUrl?currentPath=%2F%23%2Fconsole%2Fbalance"
        )!
        webView.load(URLRequest(url: loginURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private let onAuthenticated: @MainActor () -> Void
        private var isChecking = false
        private var didComplete = false

        init(onAuthenticated: @escaping @MainActor () -> Void) {
            self.onAuthenticated = onAuthenticated
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            checkAuthentication()
        }

        private func checkAuthentication() {
            guard !isChecking, !didComplete else { return }
            isChecking = true
            Task { @MainActor in
                defer { isChecking = false }
                guard (try? await MiMoOfficialUsageService.shared.fetch()) != nil else {
                    return
                }
                didComplete = true
                onAuthenticated()
            }
        }
    }
}
