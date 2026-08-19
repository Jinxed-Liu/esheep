import SwiftUI

struct AccountAccessSettingsRow: View {
    @Environment(AppSession.self) private var session

    let authenticationMethod: AccountAuthenticationMethod

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: session.accountAccessStatus.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(session.accountAccessStatus.tint.gradient, in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("登录与安全")
                session.accountAccessStatus.subtitleView(for: authenticationMethod)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if session.accountAccessStatus == .checking {
                ProgressView()
                    .controlSize(.small)
            } else if let actionTitle = session.accountAccessStatus.actionTitle {
                Button(LocalizedStringKey(actionTitle), action: performAction)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func performAction() {
        if session.accountAccessStatus.requiresSignIn {
            session.isReauthenticationPresented = true
        } else {
            session.requestAuthenticationRefresh()
        }
    }
}

struct AccountAccessNoticeCard: View {
    @Environment(AppSession.self) private var session

    let authenticationMethod: AccountAuthenticationMethod

    var body: some View {
        if session.accountAccessStatus.showsNotice {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: session.accountAccessStatus.systemImage)
                    .foregroundStyle(session.accountAccessStatus.tint)

                VStack(alignment: .leading, spacing: 4) {
                    session.accountAccessStatus.titleView(for: authenticationMethod)
                        .font(.headline)
                    session.accountAccessStatus.noticeMessageView
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if let actionTitle = session.accountAccessStatus.actionTitle {
                    Button(LocalizedStringKey(actionTitle), action: performAction)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(16)
            .background(
                session.accountAccessStatus.tint.opacity(0.10),
                in: .rect(cornerRadius: 18)
            )
        }
    }

    private func performAction() {
        if session.accountAccessStatus.requiresSignIn {
            session.isReauthenticationPresented = true
        } else {
            session.requestAuthenticationRefresh()
        }
    }
}

struct AccountAccessWorkspaceBanner: View {
    @Environment(AppSession.self) private var session

    let authenticationMethod: AccountAuthenticationMethod

    var body: some View {
        if session.accountAccessStatus.showsNotice {
            HStack(spacing: 10) {
                Image(systemName: session.accountAccessStatus.systemImage)
                    .foregroundStyle(session.accountAccessStatus.tint)

                session.accountAccessStatus.workspaceMessageView(for: authenticationMethod)
                    .font(.footnote)
                    .lineLimit(2)

                Spacer(minLength: 8)

                if let actionTitle = session.accountAccessStatus.actionTitle {
                    Button(LocalizedStringKey(actionTitle), action: performAction)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.bar)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }

    private func performAction() {
        if session.accountAccessStatus.requiresSignIn {
            session.isReauthenticationPresented = true
        } else {
            session.requestAuthenticationRefresh()
        }
    }
}

private extension AccountAccessStatus {
    var showsNotice: Bool {
        switch self {
        case .availableWithWarning, .localOnly, .requiresSignIn:
            true
        case .checking, .verified, .transferred:
            false
        }
    }

    var systemImage: String {
        switch self {
        case .checking: "arrow.trianglehead.2.clockwise.rotate.90"
        case .verified: "checkmark.shield.fill"
        case .transferred: "arrow.triangle.2.circlepath.circle.fill"
        case .availableWithWarning: "exclamationmark.shield.fill"
        case .localOnly: "wifi.slash"
        case .requiresSignIn: "person.crop.circle.badge.exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .verified: .green
        case .checking, .transferred, .availableWithWarning, .localOnly: .orange
        case .requiresSignIn: .red
        }
    }

    var actionTitle: String? {
        switch self {
        case .availableWithWarning, .localOnly:
            "重试"
        case .requiresSignIn:
            "重新登录"
        case .checking, .verified, .transferred:
            nil
        }
    }

    @ViewBuilder
    var noticeMessageView: some View {
        switch self {
        case .availableWithWarning(let message):
            Text(verbatim: message)
        case .localOnly(let message):
            Text(verbatim: message + " " + String(localized: "本地记录可继续使用，云同步已暂停。"))
        case .requiresSignIn(let message):
            Text(verbatim: message + " " + String(localized: "本地牧场与未同步记录仍然保留。"))
        case .checking:
            Text("正在后台验证，不影响本地牧场使用。")
        case .verified:
            Text("账户与云端会话正常。")
        case .transferred:
            Text("Apple 账户已转移，当前会话仍然有效。")
        }
    }

    @ViewBuilder
    func titleView(for method: AccountAuthenticationMethod) -> some View {
        switch self {
        case .checking:
            Text("正在验证登录状态")
        case .verified:
            Text(verbatim: String(localized: String.LocalizationValue(method.displayName)) + String(localized: "已验证"))
        case .transferred:
            Text("Apple 登录仍然有效")
        case .availableWithWarning:
            Text("登录状态待确认")
        case .localOnly:
            Text("当前离线使用")
        case .requiresSignIn:
            Text("账户需要重新登录")
        }
    }

    @ViewBuilder
    func subtitleView(for method: AccountAuthenticationMethod) -> some View {
        switch self {
        case .checking:
            Text(verbatim: String(localized: String.LocalizationValue(method.displayName)) + String(localized: "正在后台验证"))
        case .verified:
            Text(verbatim: String(localized: String.LocalizationValue(method.displayName)) + String(localized: "与云端会话正常"))
        case .transferred:
            Text("Apple 账户已转移，当前会话可用")
        case .availableWithWarning:
            Text("会话可用，Apple 状态稍后重试")
        case .localOnly:
            Text("本地可用，云同步已暂停")
        case .requiresSignIn:
            Text("本地记录已保留，重新登录后恢复同步")
        }
    }

    @ViewBuilder
    func workspaceMessageView(for method: AccountAuthenticationMethod) -> some View {
        switch self {
        case .availableWithWarning:
            Text(verbatim: String(localized: String.LocalizationValue(method.displayName)) + String(localized: "状态待确认，云端会话仍可用"))
        case .localOnly:
            Text("当前离线使用，本地记录正常，云同步已暂停")
        case .requiresSignIn:
            Text("需要重新登录；本地记录仍可继续查看和录入")
        case .checking:
            Text("正在后台验证登录状态")
        case .verified:
            Text("登录状态正常")
        case .transferred:
            Text("Apple 登录仍然有效")
        }
    }
}

private extension AccountAuthenticationMethod {
    var displayName: String {
        switch self {
        case .apple: "Apple 登录"
        case .password: "账号登录"
        }
    }
}
