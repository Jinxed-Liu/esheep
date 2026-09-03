import SwiftUI

struct SupabaseFarmRestoreProgressView: View {
    let record: FarmRemoteRestoreRecord
    @AppStorage(DevelopmentSupabaseRestoreGate.pausePointKey)
    private var restorePausePoint = ""
    @AppStorage(DevelopmentSupabaseRestoreGate.lastPausedPointKey)
    private var lastRestorePausePoint = ""

    private var entityFraction: Double {
        guard record.totalEntityCount > 0 else { return 0 }
        return min(
            1,
            Double(record.restoredEntityCount) /
                Double(record.totalEntityCount)
        )
    }

    private var assetFraction: Double {
        guard record.totalAssetCount > 0 else { return 0 }
        return min(
            1,
            Double(record.downloadedAssetCount) /
                Double(record.totalAssetCount)
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.blue)
                        Text("正在准备牧场资料")
                            .font(.title2.bold())
                        Text("资料检查完整前不会进入牧场。锁屏、关闭 App 或断网后，重新打开会自动继续。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }

                Section("接收进度") {
                    LabeledContent("阶段") {
                        Text(LocalizedStringKey(userStageTitle))
                    }
                    ProgressView(value: overallFraction)
                    LabeledContent(
                        "业务记录",
                        value:
                            "\(record.restoredEntityCount.formatted()) / " +
                            record.totalEntityCount.formatted()
                    )
                    LabeledContent(
                        "照片预览",
                        value:
                            "\(record.downloadedAssetCount.formatted()) / " +
                            record.totalAssetCount.formatted()
                    )
                    if record.lastErrorCode != nil {
                        Label(
                            "部分牧场资料没有接收完整",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        Text("联网后会从已经检查完成的位置继续；现有牧场资料不会被半成品替换。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                #if DEBUG && ESHEEP_INTERNAL_ACCEPTANCE_UI
                if Bundle.main.bundleIdentifier == "com.sheepfarm.next.dev" {
                    Section("Development 强杀验收") {
                        Picker("下一暂停点", selection: $restorePausePoint) {
                            Text("不暂停").tag("")
                            ForEach(
                                DevelopmentSupabaseRestoreGate.pausePoints,
                                id: \.rawValue
                            ) { state in
                                Text(LocalizedStringKey(state.displayName)).tag(state.rawValue)
                            }
                        }
                        if !lastRestorePausePoint.isEmpty {
                            LabeledContent(
                                "上次暂停",
                                value:
                                    FarmRemoteRestoreState(
                                        rawValue: lastRestorePausePoint
                                    )?.displayName ?? lastRestorePausePoint
                            )
                        }
                        Text("选定后将在该状态落盘时暂停。强制关闭 App 并重新打开，用于验证恢复可续跑。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                #endif
            }
            .navigationTitle("eSheep+ 云")
        }
    }

    private var userStageTitle: String {
        switch record.state {
        case .discovering:
            "连接 eSheep+ 云"
        case .downloadingCheckpoint, .rebuildingStaging, .downloadingAssets:
            "接收牧场资料"
        case .promoting, .catchingUp, .failed:
            "检查资料是否完整"
        case .completed:
            "即将完成"
        }
    }

    private var overallFraction: Double {
        switch record.state {
        case .discovering: return 0.02
        case .downloadingCheckpoint: return 0.08
        case .rebuildingStaging: return 0.12 + entityFraction * 0.48
        case .downloadingAssets: return 0.60 + assetFraction * 0.18
        case .promoting: return 0.82
        case .catchingUp:
            guard record.targetCursorRevision > 0 else { return 0.96 }
            return min(
                0.99,
                0.88 +
                    Double(record.currentCursorRevision) /
                    Double(record.targetCursorRevision) * 0.11
            )
        case .completed: return 1
        case .failed:
            return max(0.02, min(0.95, entityFraction * 0.6))
        }
    }
}
