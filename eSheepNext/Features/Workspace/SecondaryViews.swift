import SwiftData
import SwiftUI

struct AssistantStartView: View {
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query(sort: \FeedRecord.occurredAt, order: .reverse) private var feedRecords: [FeedRecord]
    @Query(sort: \HealthRecord.occurredAt, order: .reverse) private var healthRecords: [HealthRecord]
    @Query private var weights: [WeightRecord]
    @Query private var weanings: [WeaningRecord]
    @Query private var reproduction: [ReproductionRecord]
    @Query private var offspring: [LambingOffspringRecord]
    @Query private var removals: [RemovalRecord]
    @Query private var transfers: [TransferRecord]
    @Query private var memberships: [BatchMembershipRecord]
    @Query private var feedLines: [FeedRecordLine]
    let farm: FarmRecord
    @State private var question = ""
    @State private var answer: LocalFarmAnswer?
    @State private var analyticsSnapshot: FarmAnalyticsSnapshot?

    private var farmSheep: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    private var farmFeeds: [FeedRecord] { feedRecords.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    private var farmHealth: [HealthRecord] { healthRecords.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    private var sourceRevision: [Int] { [sheep.count, pens.count, feedRecords.count, healthRecords.count, weights.count, weanings.count, reproduction.count, offspring.count, removals.count, transfers.count, memberships.count, feedLines.count] }

    private func makeAnalyticsSnapshot() -> FarmAnalyticsSnapshot {
        FarmAnalyticsSnapshot.make(farmID: farm.id, sheep: sheep, pens: pens, weights: weights, weanings: weanings, reproduction: reproduction, offspring: offspring, removals: removals, transfers: transfers, memberships: memberships, feeds: feedRecords, feedLines: feedLines)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("牧场本地助手", systemImage: "sparkles")
                                .font(.headline)
                            Text("回答只读取当前牧场的本地数据；不会虚构记录，也不会直接写入数据。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if let answer {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(answer.text)
                                if !answer.sources.isEmpty { Text(answer.sources.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("可查询").font(.headline)
                        ForEach(["当前有多少只羊", "今天投喂了几次", "有多少个圈舍", "健康记录有多少条"], id: \.self) { prompt in
                            Button(prompt) { ask(prompt) }.buttonStyle(.bordered)
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            assistantComposer
        }
        .background(AppTheme.pageBackground)
        .navigationTitle("AI 助手")
        .onAppear { analyticsSnapshot = makeAnalyticsSnapshot() }
        .onChange(of: sourceRevision) { _, _ in analyticsSnapshot = makeAnalyticsSnapshot() }
    }

    private var assistantComposer: some View {
        HStack(spacing: 10) {
            TextField("询问当前牧场", text: $question)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit { ask(question) }
            Button { ask(question) } label: { Image(systemName: "arrow.up.circle.fill") }
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送问题")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func ask(_ text: String) {
        answer = LocalFarmAssistant.answer(question: text, activeSheep: farmSheep, pens: farmPens, feedRecords: farmFeeds, healthRecords: farmHealth, analyticsSnapshot: analyticsSnapshot)
        question = ""
    }
}

struct FarmSearchView: View {
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @Binding var query: String

    private var resultsSheep: [SheepRecord] {
        sheep.filter { item in
            item.farmID == farm.id && item.deletedAt == nil &&
                (query.isEmpty || item.earTag.localizedCaseInsensitiveContains(query) || item.breed.localizedCaseInsensitiveContains(query))
        }
    }

    private var resultsPens: [PenRecord] {
        pens.filter { item in item.farmID == farm.id && item.deletedAt == nil && (query.isEmpty || item.name.localizedCaseInsensitiveContains(query)) }
    }

    private var penNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: pens.filter { $0.farmID == farm.id && $0.deletedAt == nil }.map { ($0.id, $0.name) })
    }

    var body: some View {
        List {
            if !resultsSheep.isEmpty {
                Section("羊只") {
                    ForEach(resultsSheep, id: \.id) { item in
                        NavigationLink {
                            SheepDetailView(
                                account: account,
                                farm: farm,
                                sheep: item,
                                penName: item.currentPenID.flatMap { penNames[$0] }
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.earTag).font(.headline)
                                Text("\(item.breed) · \(item.status.displayName)").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !resultsPens.isEmpty {
                Section("圈舍") {
                    ForEach(resultsPens, id: \.id) { pen in
                        NavigationLink {
                            PenDetailView(
                                farm: farm,
                                pen: pen,
                                sheep: sheep.filter {
                                    $0.farmID == farm.id &&
                                        $0.currentPenID == pen.id &&
                                        $0.status == .active &&
                                        $0.deletedAt == nil
                                }
                            )
                        } label: {
                            Text(pen.name)
                        }
                    }
                }
            }
            if !query.isEmpty && resultsSheep.isEmpty && resultsPens.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .navigationTitle("搜索")
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "耳号、品种或圈舍"
        )
    }
}

struct FarmSettingsView: View {
    let account: AccountProfile
    let farm: FarmRecord

    var body: some View {
        List {
            Section("账户") {
                LabeledContent("显示名称", value: account.displayName)
                LabeledContent("登录绑定", value: account.serverBindingState == .verified ? "已验证" : "等待 AppleAuthBroker 验证")
                NavigationLink {
                    SubscriptionSettingsView(account: account)
                } label: {
                    Label("订阅与购买", systemImage: "creditcard")
                }
                Text("原始 Apple 登录标识只保存在本机 Keychain，不写入牧场数据。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("当前牧场") {
                LabeledContent("名称", value: farm.name)
                LabeledContent("角色", value: farm.role.displayName)
                LabeledContent("本地数据", value: "按牧场隔离")
                if CapabilitySet(role: farm.role).allows(.editFarmLocation) {
                    NavigationLink {
                        FarmLocationSettingsView(account: account, farm: farm)
                    } label: {
                        LabeledContent("牧场位置", value: farm.locationSnapshot?.displayName ?? "尚未设置")
                    }
                } else {
                    LabeledContent("牧场位置", value: farm.locationSnapshot?.displayName ?? "尚未设置")
                    Text("牧场位置仅可由场主或管理员修改。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("隐私与安全") {
                Text("第三方 AI 默认关闭；未得到用户同意不会发送牧场数据。应用不使用广告、跟踪或 ATT。")
                Text("订阅交易由 App Store 验证并按当前 eSheep+ 账户绑定；切换账号不会串用其他账号的权益。")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(LegalDocument.allCases) { document in
                    NavigationLink(document.title) {
                        LegalDocumentView(document: document)
                    }
                }
            }
            Section("云端协作") {
                NavigationLink {
                    CloudCollaborationCenterView(account: account, farm: farm)
                } label: {
                    Label("身份、共享与同步", systemImage: "person.2.icloud")
                }
            }
            Section("账户操作") {
                AccountSignOutButton()
            }
        }
        .navigationTitle("设置")
    }
}
