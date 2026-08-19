import SwiftUI

struct LocalStoreRecoveryView: View {
    let bootstrap: AppBootstrapController
    let failure: LocalStoreLaunchFailure

    @State private var isConfirmingQuarantine = false

    var body: some View {
        @Bindable var bootstrap = bootstrap

        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text("本地数据暂时无法打开")
                            .font(.title2.bold())
                        Text("App 没有删除或覆盖数据库。你可以重试，导出诊断，或者把原数据库完整隔离后进入备份与云恢复流程。")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Schema", value: AppSchema.currentVersion)
                        LabeledContent("错误代码", value: "\(failure.errorDomain) / \(failure.errorCode)")
                        Text(LocalizedStringKey(failure.summary))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 16))

                    Button {
                        bootstrap.retry()
                    } label: {
                        Label("重新尝试打开", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bootstrap.isRetrying)

                    ShareLink(
                        item: failure.diagnosticText,
                        subject: Text("eSheepNext 本地数据库诊断")
                    ) {
                        Label("导出诊断报告", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        isConfirmingQuarantine = true
                    } label: {
                        Label("隔离旧数据库并进入恢复", systemImage: "archivebox")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(bootstrap.isRetrying)

                    Text("隔离操作会把数据库、WAL、SHM 和外部存储目录移动到 App 沙盒中的 RecoveryQuarantine，不会删除它们。随后可登录并使用现有完整备份或云端恢复。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 560)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("数据恢复")
            .overlay {
                if bootstrap.isRetrying {
                    ProgressView("正在检查本地数据")
                        .padding(18)
                        .background(.regularMaterial, in: .rect(cornerRadius: 14))
                }
            }
            .confirmationDialog(
                "确认隔离本地数据库？",
                isPresented: $isConfirmingQuarantine,
                titleVisibility: .visible
            ) {
                Button("隔离并启动空白数据库", role: .destructive) {
                    bootstrap.quarantineAndStartFresh()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("原数据库会完整保留，但 App 将启动新的空白本地数据库。请确认你拥有本地备份或已完成云端验收。")
            }
        }
    }
}
