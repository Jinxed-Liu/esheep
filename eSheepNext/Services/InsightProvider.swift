import Foundation

enum InsightProvider: String, CaseIterable, Identifiable, Sendable {
    case mimo, openai
    var id: String { rawValue }
    var title: String { self == .mimo ? "MiMo" : "OpenAI" }
    var supportsAudio: Bool { self == .mimo }
    func acceptsHistory(providers: [String]) -> Bool {
        providers.filter { $0 != "local" }.allSatisfy { $0 == rawValue }
    }

    static func selected(for accountID: UUID) -> Self {
        Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey(accountID)) ?? "") ?? .mimo
    }
    func select(for accountID: UUID) {
        UserDefaults.standard.set(rawValue, forKey: Self.preferenceKey(accountID))
    }
    private static func preferenceKey(_ accountID: UUID) -> String { "insights.provider.\(accountID.uuidString.lowercased())" }

    private func modelKey(_ accountID: UUID) -> String {
        "insights.model.\(accountID.uuidString.lowercased()).\(rawValue)"
    }

    func savedModel(for accountID: UUID) -> String? {
        UserDefaults.standard.string(forKey: modelKey(accountID))
    }

    func selectModel(_ model: String, for accountID: UUID) {
        UserDefaults.standard.set(model, forKey: modelKey(accountID))
    }

    var availableModels: [String] {
        switch self {
        case .mimo: [MiMoCredential.model]
        case .openai: [MiMoCredential.openAIModel, "gpt-5.4-mini", "gpt-5.5", "gpt-6-luna", "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra"]
        }
    }

    func model(for accountID: UUID) throws -> String {
        let model = savedModel(for: accountID) ?? (self == .openai ? MiMoCredential.openAIModel : MiMoCredential.model)
        guard availableModels.contains(model) else { throw InsightProviderError.unavailableModel }
        return model
    }

    func hasConsent(for accountID: UUID) -> Bool {
        self == .mimo ? AIPrivacyConsentStore.hasCurrentConsent(for: accountID) : OpenAIConsent.hasConsent(for: accountID)
    }
    func credential(for accountID: UUID) async throws -> MiMoCredential? {
        if self == .mimo { return try await MiMoCredentialVault.shared.credential(for: accountID) }
        guard let data = try SecureAccountStore.data(account: Self.openAIKey(accountID)),
              let key = String(data: data, encoding: .utf8) else { return nil }
        return try MiMoCredential(openAIKey: key)
    }
    func save(_ credential: MiMoCredential, for accountID: UUID) async throws {
        if self == .mimo {
            guard credential.kind != .openAI else { throw InsightOpenAIError.invalidKey }
            _ = try await MiMoCredentialVault.shared.save(apiKey: credential.apiKey, for: accountID)
        } else {
            guard credential.kind == .openAI else { throw InsightOpenAIError.invalidKey }
            try SecureAccountStore.save(Data(credential.apiKey.utf8), account: Self.openAIKey(accountID))
        }
    }
    func removeCredential(for accountID: UUID) async throws {
        if self == .mimo { try await MiMoCredentialVault.shared.remove(for: accountID) }
        else { try SecureAccountStore.remove(account: Self.openAIKey(accountID)) }
    }
    private static func openAIKey(_ id: UUID) -> String { "insights.openai-api-key.\(id.uuidString.lowercased())" }
}

enum InsightOpenAIError: LocalizedError {
    case invalidKey, unsupportedAudio
    var errorDescription: String? {
        switch self {
        case .invalidKey: "请输入有效的 OpenAI API Key（sk- 开头）。"
        case .unsupportedAudio: "当前 OpenAI 通道支持文字和图片。请使用键盘听写转成文字，或切换到 MiMo 发送录音。"
        }
    }
}

enum OpenAIConsent {
    static let version = "2026-11-05"
    static let notice = "使用你自己的 OpenAI API Key 和 API 额度。本次问题、会话上下文、主动添加的图片和经授权查询的牧场结果，由这台 iPhone 直接发送给 OpenAI；处理可能发生在境外。请求设置 store=false，OpenAI 仍可能按其数据政策保留安全日志。Key 单独保存在本机钥匙串，用于直接验证 OpenAI 请求。AI 生成的录入草稿须由你确认。"
    static func hasConsent(for id: UUID) -> Bool { UserDefaults.standard.string(forKey: key(id)) == version }
    static func setConsent(_ enabled: Bool, for id: UUID) {
        if enabled { UserDefaults.standard.set(version, forKey: key(id)) }
        else { UserDefaults.standard.removeObject(forKey: key(id)) }
    }
    private static func key(_ id: UUID) -> String { "insights.openai-consent.\(id.uuidString.lowercased())" }
}

enum InsightProviderError: LocalizedError {
    case unavailableModel, incompatibleHistory

    var errorDescription: String? {
        switch self {
        case .unavailableModel: "请在 AI 助手设置中选择可用模型。"
        case .incompatibleHistory: "请切回这个会话原来使用的 AI 服务，或新建对话。"
        }
    }
}
