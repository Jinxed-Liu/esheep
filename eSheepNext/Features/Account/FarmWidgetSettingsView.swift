import SwiftData
import SwiftUI
import WidgetKit

struct FarmWidgetSettingsView: View {
    let farm: FarmRecord
    @State private var profiles: [FarmWidgetProfile] = []
    @State private var snapshot = FarmWidgetSnapshot.empty
    @State private var editing: FarmWidgetProfile?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Label("11 类小组件 · 9 种配色", systemImage: "square.grid.2x2")
                    .font(.headline)
                Text("在这里保存配置；长按桌面上的小组件，选择“编辑小组件”，再选择对应类型的“使用配置”。每份配置独立保存，支持同时关注不同圈舍或批次。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !snapshot.farms.contains(where: { $0.farmID == farm.id }) {
                    Text("此牧场尚未发布可用快照。完成登录与云端牧场加载后会自动更新。")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            Section("\(farm.name) · 已保存配置") {
                if profiles.isEmpty { Text("从下方选择一种小组件开始配置").foregroundStyle(.secondary) }
                ForEach(profiles) { profile in
                    Button { editing = profile } label: {
                        HStack {
                            Image(systemName: profile.kind.symbol).foregroundStyle(profile.palette.color)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).foregroundStyle(.primary)
                                Text("\(profile.kind.title) · \(profile.palette.title)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { delete(profile) }
                    }
                }
            }
            Section("彩色推荐 · 小号与中号") {
                ForEach(FarmWidgetPalette.colorful) { palette in
                    Button {
                        editing = FarmWidgetProfile(farmID: farm.id, name: "\(farm.name) · \(palette.title)",
                                                    kind: palette.suggestedKind, palette: palette)
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(LinearGradient(colors: palette.gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 42, height: 42)
                                .overlay { Image(systemName: palette.suggestedKind.symbol).foregroundStyle(palette.colorfulInk) }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(palette.title).foregroundStyle(.primary)
                                Text(palette.suggestedKind.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(.tint)
                        }
                    }
                }
            }
            Section("小组件库") {
                ForEach(FarmWidgetKind.allCases) { kind in
                    Button {
                        editing = FarmWidgetProfile(farmID: farm.id, name: "\(farm.name) · \(kind.title)", kind: kind, palette: kind.defaultPalette)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: kind.symbol)
                                .font(.title3).foregroundStyle(kind.defaultPalette.color).frame(width: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(kind.title).foregroundStyle(.primary)
                                Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "plus.circle").foregroundStyle(.tint)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
            Section("数据说明") {
                Text("显示的是 App 发布的数据快照。超过一小时或跨过牧场当地午夜时会提示过期；打开 App 后更新。刷新时机由系统调度。")
                Text("称重覆盖使用当前在场名单；增重表现使用所选期间的有效样本，圈舍只归属连续在舍区间，批次遵循历史成员关系。")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("小组件设置")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("widget-settings")
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: FarmWidgetProfileStore.changeNotification)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: FarmWidgetSnapshotStore.changeNotification).receive(on: RunLoop.main)) { _ in reload() }
        .sheet(item: $editing) { profile in
            NavigationStack { FarmWidgetProfileEditor(farm: farm, initial: profile, snapshot: snapshot) }
        }
        .alert("未能保存配置", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func reload() {
        profiles = FarmWidgetProfileStore.load().filter { $0.farmID == farm.id }
        snapshot = FarmWidgetSnapshotStore.load()
    }
    private func delete(_ profile: FarmWidgetProfile) {
        do {
            try FarmWidgetProfileStore.save(FarmWidgetProfileStore.load().filter { $0.id != profile.id })
            WidgetCenter.shared.reloadAllTimelines()
            reload()
        } catch { self.error = error.localizedDescription }
    }
}

private struct FarmWidgetProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query(sort: \ProductionBatchRecord.name) private var batches: [ProductionBatchRecord]
    let farm: FarmRecord
    let snapshot: FarmWidgetSnapshot
    @State private var profile: FarmWidgetProfile
    @State private var medium = true
    @State private var error: String?

    init(farm: FarmRecord, initial: FarmWidgetProfile, snapshot: FarmWidgetSnapshot) {
        self.farm = farm; self.snapshot = snapshot
        _profile = State(initialValue: initial)
    }
    private var options: [FarmWidgetSnapshot.ScopeOption] {
        if profile.scope == .pen {
            return pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive }
                .map { .init(id: $0.id, name: $0.name, kind: .pen) }
        }
        return batches.filter { $0.farmID == farm.id && $0.deletedAt == nil }
            .map { .init(id: $0.id, name: $0.name, kind: .batch) }
    }
    private var valid: Bool {
        !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!profile.kind.needsScope || options.contains { $0.id == profile.scopeID }) &&
        (!profile.kind.needsWeightScope || CapabilitySet(role: farm.role).allows(.viewAnalytics)) &&
        (profile.period != .custom || profile.startDate <= profile.endDate)
    }
    private var preview: FarmWidgetCard {
        let stored: [FarmWidgetCard]? = snapshot.farms.first { $0.farmID == farm.id }?.cards
        var card: FarmWidgetCard
        if let matchedProfile = stored?.first(where: { $0.profileID == profile.id && $0.profileRevision == profile.revision }) {
            card = matchedProfile
        } else if let matchedKind = stored?.first(where: { $0.kind == profile.kind && $0.profileID == nil }) {
            card = matchedKind
        } else {
            card = .waiting(kind: profile.kind, message: "保存后由牧场数据生成快照")
        }
        if profile.kind.needsScope && FarmWidgetProfileStore.load().first(where: { $0.id == profile.id }) != profile {
            card = .waiting(kind: profile.kind, message: "保存后生成所选对象与日期范围的数据")
        }
        card.palette = profile.palette
        return card
    }
    var body: some View {
        Form {
            Section("预览") {
                Picker("尺寸", selection: $medium) {
                    Text("小号").tag(false); Text("中号").tag(true)
                }.pickerStyle(.segmented)
                FarmWidgetCardView(card: preview, farmName: farm.name, generatedAt: snapshot.generatedAt,
                                   timeZoneIdentifier: farm.timeZoneIdentifier, medium: medium)
                    .padding(16)
                    .frame(maxWidth: medium ? 364 : 174).frame(height: 174)
                    .background { FarmWidgetBackground(palette: profile.palette) }
                    .clipShape(.rect(cornerRadius: 25))
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            Section("独立配置") {
                TextField("配置名称", text: $profile.name)
                LabeledContent("牧场", value: farm.name)
                LabeledContent("小组件类型", value: profile.kind.title)
                Picker("配色", selection: $profile.palette) {
                    ForEach(FarmWidgetPalette.allCases) { Text($0.title).tag($0) }
                }
            }
            if profile.kind.needsScope {
                Section("关注对象") {
                    if profile.kind.needsWeightScope {
                        Picker("对象类型", selection: $profile.scope) {
                            ForEach(FarmWidgetScope.allCases) { Text($0.title).tag($0) }
                        }.onChange(of: profile.scope) { _, _ in profile.scopeID = nil }
                    }
                    Picker(profile.scope.title, selection: $profile.scopeID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(options) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if options.isEmpty { Text("没有可用的\(profile.scope.title)").foregroundStyle(.secondary) }
                }
            }
            if profile.kind.needsWeightScope {
                Section("统计周期") {
                    Picker("周期", selection: $profile.period) {
                        ForEach(FarmWidgetPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    if profile.period == .custom {
                        DatePicker("开始", selection: $profile.startDate, in: ...Date.now, displayedComponents: .date)
                            .environment(\.timeZone, TimeZone(identifier: farm.timeZoneIdentifier) ?? .gmt)
                        DatePicker("结束", selection: $profile.endDate, in: ...Date.now, displayedComponents: .date)
                            .environment(\.timeZone, TimeZone(identifier: farm.timeZoneIdentifier) ?? .gmt)
                    }
                    Text(profile.kind == .coverage ? "以当前在场羊只为分母，统计所选周期内有有效称重的去重羊只数。" : "按有效区间逐羊计算日增重后等权平均。圈舍使用连续在舍区间；批次使用期间成员关系。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !CapabilitySet(role: farm.role).allows(.viewAnalytics) {
                        Text("当前角色无权查看生产分析").foregroundStyle(.orange)
                    }
                }
            }
            Section {
                Text("保存后，长按桌面上同类型的小组件，在“使用配置”中选择本配置。再次编辑本配置，会更新引用它的所有小组件。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(profile.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(!valid) }
        }
    }
    private func save() {
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.revision = UUID()
        var all = FarmWidgetProfileStore.load()
        all.removeAll { $0.id == profile.id }
        all.append(profile)
        do {
            try FarmWidgetProfileStore.save(all)
            WidgetCenter.shared.reloadAllTimelines()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
