import SwiftData
import SwiftUI

struct PendingTroughListView: View {
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    @State private var rows: [PendingTroughSnapshot] = []
    @State private var isLoading = true
    @State private var failure: String?

    var body: some View {
        List {
            if isLoading { ProgressView("正在读取待盘槽记录") }
            if let failure { Text(failure).foregroundStyle(.orange); Button("重试") { Task { await load() } } }
            if !isLoading && failure == nil && rows.isEmpty { ContentUnavailableView("暂无待盘槽记录", systemImage: "checkmark.circle") }
            ForEach(rows) { row in
                NavigationLink {
                    FeedTroughObservationEntryView(account: account, farm: farm)
                        .environment(\.productionEntryPrefill, ProductionEntryPrefill(penID: row.penID, relatedFeedID: row.relatedFeedID))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: row.penName).font(.headline)
                        if !row.feederName.isEmpty { Text(verbatim: row.feederName).font(.footnote).foregroundStyle(.secondary) }
                        Text("最近投喂：\(row.lastFedAt.formatted())").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("待盘槽")
        .onAppear { Task { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await FeedingOverviewSnapshotActor(container: modelContext.container).load(farmID: farm.id)
            try Task.checkCancellation()
            rows = snapshot.pendingTroughRows
            failure = nil
        } catch is CancellationError { } catch { failure = error.localizedDescription }
    }
}
