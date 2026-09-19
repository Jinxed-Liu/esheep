import SwiftUI

struct ProductionEntryDestination: View {
    let entry: PendingRecordEntry
    let account: AccountProfile
    let farm: FarmRecord

    var body: some View {
        Group {
        switch entry {
        case .addSheep: AddSheepView(account: account, farm: farm)
        case .weight: WeightEntryView(account: account, farm: farm)
        case .transfer: TransferEntryView(account: account, farm: farm)
        case .removal: RemovalEntryView(account: account, farm: farm)
        case .feed: FeedEntryView(account: account, farm: farm)
        case .health: HealthBatchEntryView(account: account, farm: farm)
        case .weaning: WeaningEntryView(account: account, farm: farm)
        case .reproduction: ReproductionBatchEntryView(account: account, farm: farm)
        case .lambing: CareLambingEntryView(account: account, farm: farm)
        case .note: NoteEntryView(account: account, farm: farm)
        case .trough: FeedTroughObservationEntryView(account: account, farm: farm)
        case .tmrProduction: TMRBatchProductionView(account: account, farm: farm)
        case .tmrFeeding: TMRFeedingEntryView(account: account, farm: farm)
        }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum HomeQuickAction: String, Codable, CaseIterable, Identifiable {
    case addSheep, weight, transfer, removal, feed, exportEvents, health, weaning, reproduction, lambing, note, trough, tmrProduction, tmrFeeding
    var id: Self { self }
    static let defaults: [Self] = [.addSheep, .weight, .transfer, .removal, .feed, .exportEvents]
    var entry: PendingRecordEntry? { PendingRecordEntry(rawValue: rawValue) }
    var title: String {
        switch self {
        case .addSheep: "新建羊只"
        case .weight: "称重"
        case .transfer: "转群"
        case .removal: "离场"
        case .feed: "直接投喂"
        case .exportEvents: "事件导出"
        case .health: "健康记录"
        case .weaning: "断奶"
        case .reproduction: "配种或孕检"
        case .lambing: "产羔"
        case .note: "备注"
        case .trough: "盘槽"
        case .tmrProduction: "制作 TMR"
        case .tmrFeeding: "TMR 投喂"
        }
    }
    var symbol: String {
        switch self {
        case .addSheep: "plus.circle"
        case .weight: "scalemass"
        case .transfer: "arrow.left.arrow.right"
        case .removal: "arrowshape.turn.up.right"
        case .exportEvents: "square.and.arrow.up"
        case .health: "cross.case"
        case .reproduction: "heart.text.square"
        case .lambing: "figure.and.child.holdinghands"
        case .note: "note.text"
        case .feed: "leaf"
        case .weaning: "figure.child"
        case .trough: "scalemass"
        case .tmrProduction: "arrow.triangle.2.circlepath"
        case .tmrFeeding: "truck.box"
        }
    }
}

struct HomeQuickActionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var actions: [HomeQuickAction]
    var body: some View {
        NavigationStack {
            List {
                Section("常用操作 · 拖动排序") {
                    ForEach(actions) { action in Text(action.title) }
                        .onMove { actions.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { actions.remove(atOffsets: $0) }
                }
                Section("添加操作") {
                    ForEach(HomeQuickAction.allCases.filter { !actions.contains($0) }) { action in
                        Button(action.title, systemImage: "plus.circle") { actions.append(action) }
                    }
                }
                Button("恢复默认") { actions = HomeQuickAction.defaults }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("常用操作")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
