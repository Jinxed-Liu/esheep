import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    let account: AccountProfile

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                HStack(spacing: 16) {
                    AccountAvatarView(account: account, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.displayName)
                            .font(.headline)
                        Text("预览会随选择立即变化")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            Section("显示模式") {
                Picker("外观", selection: $preferences.appearance) {
                    ForEach(AppAppearancePreference.allCases) { option in
                        Label {
                            Text(LocalizedStringKey(option.displayName))
                        } icon: {
                            Image(systemName: option.systemImage)
                        }
                            .tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section {
                Toggle("头像动态效果", isOn: $preferences.avatarMotionEnabled)
                Text(systemReduceMotion
                    ? "系统已开启“减弱动态效果”，头像动画会自动停用。"
                    : "控制设置页头像的收拢和缩放过渡；省电模式下会自动减弱。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PowerSavingSettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("省电模式", isOn: $preferences.powerSavingEnabled)
                LabeledContent(
                    "系统低电量模式",
                    value: preferences.systemLowPowerModeEnabled ? "已开启" : "未开启"
                )
            } footer: {
                Text("省电模式会降低头像资料的自动检查频率，并减弱非必要动画；打开应用时的牧场数据同步仍会正常进行。")
            }

            Section("后台活动") {
                Toggle("允许后台刷新", isOn: $preferences.backgroundRefreshEnabled)
                Text("关闭后不再安排系统后台刷新；进入应用后仍会同步。iOS 也可能根据电量和使用习惯限制后台任务。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("动态效果") {
                Toggle("减少动态效果", isOn: $preferences.reduceMotionEnabled)
                Text("关闭设置页头像收拢、缩放等装饰动画，不影响页面跳转和业务操作。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("省电")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { preferences.refreshSystemPowerState() }
    }
}

struct LanguageSettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("显示语言") {
                Picker("语言", selection: $preferences.language) {
                    ForEach(AppLanguagePreference.allCases) { option in
                        Text(LocalizedStringKey(option.displayName)).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section {
                Label("选择 English 后，本地化文案、日期、数字和系统组件会立即切换。", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                Text("选择“跟随系统”时，日期、数字、系统组件和已本地化文案使用设备语言。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("语言")
        .navigationBarTitleDisplayMode(.inline)
    }
}
