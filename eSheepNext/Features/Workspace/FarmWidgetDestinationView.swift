import SwiftData
import SwiftUI

struct FarmWidgetDestinationView: View {
    @Environment(\.dismiss) private var dismiss
    let account: AccountProfile
    let farm: FarmRecord
    let target: FarmSystemNavigationTarget
    private var kind: FarmWidgetKind { FarmWidgetKind(rawValue: target.query ?? "") ?? .overview }
    private var profile: FarmWidgetProfile? {
        FarmWidgetProfileStore.load().first { $0.id == target.entityID && $0.farmID == farm.id && $0.kind == kind }
    }
    var body: some View {
        Group {
            if target.entityID != nil && profile == nil {
                ContentUnavailableView("配置已失效", systemImage: "square.grid.2x2", description: Text("请在小组件设置中重新选择配置。"))
            } else if kind.needsWeightScope, let profile, profile.scopeID != nil,
                      CapabilitySet(role: farm.role).allows(.viewAnalytics) {
                FarmWidgetWeightDetailView(account: account, farm: farm, profile: profile)
            } else if kind == .feeding, let profile, profile.scope == .pen, profile.scopeID != nil {
                TMRMonitoringView(account: account, farm: farm, initialPenID: profile.scopeID)
            } else if [.alerts, .pregnancy, .weaning].contains(kind) {
                FarmOperationalAlertCenterView(account: account, farm: farm)
            } else if kind == .breeding {
                CareReminderCenterView(account: account, farm: farm, focusedReminderID: nil)
            } else if kind == .sync {
                ESheepCloudCenterView(account: account, farm: farm)
            } else {
                FarmWidgetSettingsView(farm: farm)
            }
        }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
    }
}

private struct FarmWidgetWeightDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    let profile: FarmWidgetProfile
    @State private var payload: WidgetWeightEvidence?
    @State private var error: String?

    var body: some View {
        Group {
            if let payload {
                List {
                    Section {
                        FarmWidgetCardView(card: payload.card, farmName: farm.name, generatedAt: payload.snapshot.factsReadAt,
                                           timeZoneIdentifier: farm.timeZoneIdentifier, medium: true)
                            .padding(16).frame(height: 174)
                            .background { FarmWidgetBackground(palette: profile.palette) }
                            .clipShape(.rect(cornerRadius: 24))
                            .listRowInsets(EdgeInsets())
                    }
                    if profile.kind == .gain {
                        Section("增重计算依据") {
                            NavigationLink("可计算羊只与有效区间") {
                                WeightGainEvidenceList(account: account, farm: farm, result: payload.result)
                            }
                            NavigationLink("未纳入原因") {
                                WeightGainEvidenceList(account: account, farm: farm, result: payload.result, showExclusions: true)
                            }
                            Text("\(payload.result.calculableCount) 只可计算 / \(payload.result.objectCount) 只期间对象。先按羊计算有效区间日增重，再逐羊等权平均；与当前在场称重覆盖的分母不同。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section("当前名单 · 未称重 \(payload.currentIDs.subtracting(payload.weighedIDs).count) 只") {
                        sheepRows(payload, weighed: false)
                    }
                    Section("当前名单 · 已称重 \(payload.weighedIDs.count) 只") {
                        sheepRows(payload, weighed: true)
                    }
                }
            } else if let error {
                ContentUnavailableView("暂时无法读取", systemImage: "exclamationmark.triangle", description: Text(error))
            } else { ProgressView("读取称重证据…") }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: profile.revision) { await load() }
    }
    @ViewBuilder private func sheepRows(_ data: WidgetWeightEvidence, weighed: Bool) -> some View {
        ForEach(data.snapshot.sheep.filter { data.currentIDs.contains($0.id) && data.weighedIDs.contains($0.id) == weighed }.sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }, id: \.id) { sheep in
            NavigationLink(sheep.earTag) { SheepDetailEntryView(account: account, farm: farm, sheepID: sheep.id) }
        }
    }
    private func load() async {
        do {
            let source = try await FarmDeepAnalyticsSnapshotActor(container: modelContext.container).load(farmID: farm.id)
            let selectedProfile = profile
            guard let name = Self.scopeName(for: selectedProfile, in: source) else {
                error = "所选圈舍或批次已不可用，请重新配置。"
                return
            }
            let result = await Task.detached(priority: .userInitiated) { [source, profile = selectedProfile, name] in
                let now = source.snapshot.factsReadAt
                let filter = FarmWidgetSnapshotBuilder.weightFilter(profile: profile, snapshot: source.snapshot, now: now)
                let result = WeightGainAnalyticsEngine.calculate(snapshot: source.snapshot, filter: filter)
                let members = FarmWidgetSnapshotBuilder.coverageMembers(profile: profile, snapshot: source.snapshot, now: now)
                return WidgetWeightEvidence(snapshot: source.snapshot, result: result,
                    card: FarmWidgetSnapshotBuilder.weightCard(profile: profile, scopeName: name, snapshot: source.snapshot, now: now, gainResult: result),
                    currentIDs: members.current, weighedIDs: members.weighed)
            }.value
            try Task.checkCancellation()
            payload = result
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }

    // Keep synchronous search closures out of the async view-state lifetime.
    private nonisolated static func scopeName(for profile: FarmWidgetProfile, in source: FarmDeepAnalyticsPayload) -> String? {
        if profile.scope == .pen {
            return source.snapshot.pens.first { $0.id == profile.scopeID && $0.isActive }?.name
        }
        return source.batches.first { $0.id == profile.scopeID }?.name
    }
}
private struct WidgetWeightEvidence: Sendable {
    let snapshot: FarmAnalyticsSnapshot
    let result: WeightGainAnalysisResult
    let card: FarmWidgetCard
    let currentIDs: Set<UUID>
    let weighedIDs: Set<UUID>
}
