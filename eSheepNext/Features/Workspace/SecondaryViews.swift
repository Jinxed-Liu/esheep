import SwiftData
import SwiftUI
import UIKit

private enum FarmInsightsSection: String, CaseIterable, Identifiable {
    case overview
    case assistant

    var id: String { rawValue }
    var title: String { self == .overview ? "分析" : "问助手" }
}

struct FarmInsightsView: View {
    let farm: FarmRecord
    @State private var section = FarmInsightsSection.overview

    var body: some View {
        VStack(spacing: 0) {
            Picker("洞察内容", selection: $section) {
                ForEach(FarmInsightsSection.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            switch section {
            case .overview:
                FarmAnalysisCenterView(farm: farm) {
                    withAnimation(.snappy) { section = .assistant }
                }
            case .assistant:
                AssistantStartView(farm: farm)
            }
        }
        .background(AppTheme.pageBackground)
        .navigationTitle("牧场洞察")
    }
}

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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                assistantHeader

                if let answer {
                    answerCard(answer)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("直接问数据")
                            .font(.title2.bold())
                        Text("我会从当前牧场的真实记录里找答案，并标出计算来源。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("可以这样问")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(suggestedQuestions, id: \.self) { prompt in
                            Button(prompt) { ask(prompt) }
                                .buttonStyle(.bordered)
                                .tint(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .safeAreaPadding(.bottom, 100)
        }
        .background(AppTheme.pageBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            assistantComposer
        }
        .onAppear { analyticsSnapshot = makeAnalyticsSnapshot() }
        .onChange(of: sourceRevision) { _, _ in analyticsSnapshot = makeAnalyticsSnapshot() }
    }

    private var suggestedQuestions: [String] {
        ["当前有多少只羊", "今天投喂了几次", "哪个圈舍羊最多", "查看一只羊的完整档案"]
    }

    private var assistantHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(AppTheme.brand.gradient, in: .rect(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 5) {
                Text("牧场本地助手")
                    .font(.headline)
                Label("只读 · 当前牧场 · 不上传", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func answerCard(_ answer: LocalFarmAnswer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("基于牧场记录")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(answer.text)
                .font(.body)
                .textSelection(.enabled)
            if !answer.sources.isEmpty {
                Divider()
                Text(answer.sources.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.background, in: .rect(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).stroke(.separator.opacity(0.45), lineWidth: 0.5) }
    }

    private var assistantComposer: some View {
        HStack(spacing: 10) {
            TextField("询问当前牧场", text: $question)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.fill.quaternary, in: .capsule)
                .submitLabel(.send)
                .onSubmit { ask(question) }
            Button { ask(question) } label: {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(AppTheme.brand, in: .circle)
            }
            .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送问题")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func ask(_ text: String) {
        let submitted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty else { return }
        answer = LocalFarmAssistant.answer(question: submitted, activeSheep: farmSheep, pens: farmPens, feedRecords: farmFeeds, healthRecords: farmHealth, analyticsSnapshot: analyticsSnapshot)
        question = ""
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
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
            Section {
                AccountAvatarEditor(account: account)
            }
            Section("账户") {
                LabeledContent("显示名称", value: account.displayName)
                LabeledContent("登录绑定", value: account.serverBindingState == .verified ? "CloudBase 已验证" : "等待 CloudBase 验证")
                if SubscriptionFeatureConfiguration.isEnabled {
                    NavigationLink {
                        SubscriptionSettingsView(account: account)
                    } label: {
                        Label("订阅与购买", systemImage: "creditcard")
                    }
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
                NavigationLink {
                    SystemServicesSettingsView(farm: farm)
                } label: {
                    Label("通知与系统能力", systemImage: "bell.badge")
                }
            }
            Section("数据") {
                NavigationLink {
                    FarmDataInterchangeView(account: account, farm: farm)
                } label: {
                    Label("导入与导出", systemImage: "arrow.up.arrow.down.square")
                }
            }
            Section("账户操作") {
                AccountSignOutButton()
            }
        }
        .navigationTitle("设置")
    }
}
