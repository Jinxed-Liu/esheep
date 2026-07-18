import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct HerdManagementView: View {
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]

    let account: AccountProfile
    let farm: FarmRecord

    @State private var isAddingSheep = false
    @State private var isExportingSheep = false
    @State private var exportDocument: InHerdSheepExportDocument?
    @State private var exportMessage: String?
    @State private var query = ""

    private var farmSheep: [SheepRecord] {
        sheep.filter {
            $0.farmID == farm.id && $0.deletedAt == nil &&
                (query.isEmpty || $0.earTag.localizedCaseInsensitiveContains(query) || $0.breed.localizedCaseInsensitiveContains(query))
        }
    }

    private var penNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: pens.filter { $0.farmID == farm.id }.map { ($0.id, $0.name) })
    }

    private var presentSheep: [SheepRecord] {
        sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isCurrentlyPresent }
    }

    var body: some View {
        List {
            if farmSheep.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(farmSheep, id: \.id) { sheep in
                    NavigationLink {
                        SheepDetailView(account: account, farm: farm, sheep: sheep, penName: sheep.currentPenID.flatMap { penNames[$0] })
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sheep.earTag).font(.headline)
                            Text([sheep.breed, sheep.sex.displayName, sheep.currentPenDisplayName(sheep.currentPenID.flatMap { penNames[$0] }), sheep.status.displayName].joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("羊只")
        .searchable(text: $query, prompt: "耳号或品种")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { exportPresentSheep() } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("导出在群羊只 Excel")
                    .disabled(presentSheep.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { isAddingSheep = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建羊只")
            }
        }
        .sheet(isPresented: $isAddingSheep) {
            NavigationStack { AddSheepView(account: account, farm: farm) }
        }
        .fileExporter(
            isPresented: $isExportingSheep,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: InHerdSheepExport.fileName(farmName: farm.name)
        ) { result in
            switch result {
            case .success:
                exportMessage = "已导出 \(presentSheep.count) 只在群羊只。文件为 UTF-8 CSV，可直接用 Excel 打开。"
            case .failure(let error):
                exportMessage = "导出失败：\(error.localizedDescription)"
            }
        }
        .alert("导出羊只", isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })) {
            Button("完成", role: .cancel) {}
        } message: {
            Text(exportMessage ?? "")
        }
    }

    private func exportPresentSheep() {
        exportDocument = InHerdSheepExportDocument(
            data: InHerdSheepExport.csvData(farmID: farm.id, sheep: presentSheep, pens: pens)
        )
        isExportingSheep = true
    }
}

struct SheepDetailView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Query private var allSheep: [SheepRecord]
    @Query private var pens: [PenRecord]
    @Query(sort: \WeightRecord.occurredAt, order: .reverse) private var weights: [WeightRecord]
    @Query private var weanings: [WeaningRecord]
    @Query(sort: \TransferRecord.occurredAt, order: .reverse) private var transfers: [TransferRecord]
    @Query(sort: \HealthRecord.occurredAt, order: .reverse) private var healthRecords: [HealthRecord]
    @Query(sort: \ReproductionRecord.occurredAt, order: .reverse) private var reproductionRecords: [ReproductionRecord]
    @Query private var offspring: [LambingOffspringRecord]
    @Query private var removals: [RemovalRecord]
    @Query private var memberships: [BatchMembershipRecord]
    @Query private var feeds: [FeedRecord]
    @Query private var feedLines: [FeedRecordLine]
    @Query(sort: \PhotoAssetRecord.createdAt, order: .reverse) private var photos: [PhotoAssetRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let sheep: SheepRecord
    let penName: String?

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isProcessingPhoto = false
    @State private var photoMessage: String?
    @State private var lifecycleInsight: FarmInsight?
    @State private var reproductionInsight: FarmInsight?

    private var sheepPhotos: [PhotoAssetRecord] {
        photos.filter { $0.farmID == farm.id && $0.sheepID == sheep.id && $0.deletedAt == nil }
    }

    private var analyticsSourceRevision: [Int] { [allSheep.count, pens.count, weights.count, weanings.count, transfers.count, reproductionRecords.count, offspring.count, removals.count, memberships.count, feeds.count, feedLines.count] }

    private func makeAnalyticsSnapshot() -> FarmAnalyticsSnapshot {
        FarmAnalyticsSnapshot.make(farmID: farm.id, sheep: allSheep, pens: pens, weights: weights, weanings: weanings, reproduction: reproductionRecords, offspring: offspring, removals: removals, transfers: transfers, memberships: memberships, feeds: feeds, feedLines: feedLines)
    }

    var body: some View {
        List {
            Section("档案") {
                LabeledContent("耳号", value: sheep.earTag)
                LabeledContent("品种", value: sheep.breed)
                LabeledContent("性别", value: sheep.sex.displayName)
                LabeledContent("状态", value: sheep.status.displayName)
                LabeledContent("当前圈舍", value: sheep.currentPenDisplayName(penName))
                LabeledContent("入场时间") { Text(sheep.enteredAt, format: .dateTime.year().month().day()) }
            }
            if !sheep.note.isEmpty {
                Section("备注") { Text(sheep.note) }
            }
            analyticsSection
            Section("照片") {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("从照片库添加", systemImage: "photo.badge.plus")
                }
                .disabled(isProcessingPhoto || !FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role).capabilities.allows(.recordProduction))
                if isProcessingPhoto { ProgressView("正在处理照片") }
                if sheepPhotos.isEmpty {
                    Text("尚未添加照片").foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 12) {
                            ForEach(sheepPhotos, id: \.id) { photo in
                                CloudPhotoThumbnail(assetID: photo.id, digest: photo.sha256)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            timelineSection
        }
        .navigationTitle(sheep.earTag)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            addPhoto(item)
        }
        .onAppear(perform: refreshInsights)
        .onChange(of: analyticsSourceRevision) { _, _ in refreshInsights() }
        .alert("照片", isPresented: Binding(get: { photoMessage != nil }, set: { if !$0 { photoMessage = nil } })) {
            Button("完成", role: .cancel) {}
        } message: { Text(photoMessage ?? "") }
    }

    @ViewBuilder
    private var analyticsSection: some View {
        if let lifecycleInsight {
            Section(lifecycleInsight.title) {
                Text(lifecycleInsight.summary)
                ForEach(lifecycleInsight.details, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            }
        } else {
            Section { ProgressView("正在计算羊只分析") }
        }
        if let reproductionInsight, !reproductionInsight.details.isEmpty {
            Section(reproductionInsight.title) {
                Text(reproductionInsight.summary)
                ForEach(reproductionInsight.details, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    private func refreshInsights() {
        let snapshot = makeAnalyticsSnapshot()
        let sheepID = sheep.id
        Task {
            let insights = await Task.detached(priority: .userInitiated) {
                (
                    SheepAnalyticsEngine.lifecycle(sheepID: sheepID, snapshot: snapshot),
                    SheepAnalyticsEngine.reproduction(sheepID: sheepID, snapshot: snapshot)
                )
            }.value
            lifecycleInsight = insights.0
            reproductionInsight = insights.1
        }
    }

    @ViewBuilder
    private var timelineSection: some View {
        let entries = timelineEntries
        Section("时间线") {
            if entries.isEmpty {
                Text("暂无历史记录").foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title).font(.subheadline.weight(.medium))
                        if !entry.detail.isEmpty { Text(entry.detail).font(.footnote).foregroundStyle(.secondary) }
                        Text(entry.date, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var timelineEntries: [SheepTimelineEntry] {
        let weightEntries = weights.filter { $0.sheepID == sheep.id && $0.deletedAt == nil }
            .map { SheepTimelineEntry(id: $0.id, title: "称重", detail: "\($0.kilogramsText) 千克", date: $0.occurredAt) }
        let transferEntries = transfers.filter { $0.sheepID == sheep.id && $0.deletedAt == nil }
            .map { SheepTimelineEntry(id: $0.id, title: "转群", detail: $0.note, date: $0.occurredAt) }
        let healthEntries = healthRecords.filter { $0.sheepID == sheep.id && $0.deletedAt == nil }
            .map { SheepTimelineEntry(id: $0.id, title: $0.kindRawValue == HealthRecordKind.vaccination.rawValue ? "疫苗" : "治疗", detail: $0.itemNameSnapshot, date: $0.occurredAt) }
        let reproductionEntries = reproductionRecords.filter { $0.eweID == sheep.id && $0.deletedAt == nil }
            .map { SheepTimelineEntry(id: $0.id, title: ReproductionRecordKind(rawValue: $0.kindRawValue)?.displayName ?? "繁殖", detail: $0.note, date: $0.occurredAt) }
        return (weightEntries + transferEntries + healthEntries + reproductionEntries).sorted { $0.date > $1.date }
    }

    private func addPhoto(_ item: PhotosPickerItem) {
        guard !isProcessingPhoto else { return }
        isProcessingPhoto = true
        Task {
            defer {
                isProcessingPhoto = false
                selectedPhoto = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoTransferError.sourceUnreadable }
                _ = try await collaboration.photoTransfers.enqueue(data: data, farmID: farm.id, entityID: sheep.id)
                await collaboration.synchronizeNow()
                photoMessage = collaboration.lastErrorMessage ?? "照片已压缩保存并进入云端同步队列。"
            } catch {
                photoMessage = error.localizedDescription
            }
        }
    }
}

private struct CloudPhotoThumbnail: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    let assetID: UUID
    let digest: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(.rect(cornerRadius: 16))
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .task(id: digest) {
            if let data = try? await collaboration.photoTransfers.localFileData(assetID: assetID) {
                image = UIImage(data: data)
            }
        }
    }
}

private struct SheepTimelineEntry: Identifiable {
    let id: UUID
    let title: String
    let detail: String
    let date: Date
}

struct PenManagementView: View {
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]

    let account: AccountProfile
    let farm: FarmRecord
    @State private var isAddingPen = false

    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil } }

    var body: some View {
        List {
            ForEach(farmPens, id: \.id) { pen in
                NavigationLink {
                    PenDetailView(farm: farm, pen: pen, sheep: sheep.filter { $0.farmID == farm.id && $0.currentPenID == pen.id && $0.status == .active && $0.deletedAt == nil })
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pen.name).font(.headline)
                        Text("当前羊只 \(sheep.filter { $0.farmID == farm.id && $0.currentPenID == pen.id && $0.status == .active && $0.deletedAt == nil }.count) 只")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if farmPens.isEmpty {
                ContentUnavailableView("还没有圈舍", systemImage: "building.2", description: Text("圈舍是羊只、投喂和历史分析的核心单位。"))
            }
        }
        .navigationTitle("圈舍")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { isAddingPen = true } label: { Image(systemName: "plus") } }
        }
        .sheet(isPresented: $isAddingPen) { NavigationStack { AddPenView(account: account, farm: farm) } }
    }
}

struct PenDetailView: View {
    @Query private var allSheep: [SheepRecord]
    @Query private var allPens: [PenRecord]
    @Query private var weights: [WeightRecord]
    @Query private var weanings: [WeaningRecord]
    @Query private var reproduction: [ReproductionRecord]
    @Query private var offspring: [LambingOffspringRecord]
    @Query private var removals: [RemovalRecord]
    @Query private var transfers: [TransferRecord]
    @Query private var memberships: [BatchMembershipRecord]
    @Query private var feeds: [FeedRecord]
    @Query private var feedLines: [FeedRecordLine]

    let farm: FarmRecord
    let pen: PenRecord
    let sheep: [SheepRecord]
    @State private var herdInsight: FarmInsight?

    private var analyticsSourceRevision: [Int] { [allSheep.count, allPens.count, weights.count, weanings.count, reproduction.count, offspring.count, removals.count, transfers.count, memberships.count, feeds.count, feedLines.count] }

    private func makeAnalyticsSnapshot() -> FarmAnalyticsSnapshot {
        FarmAnalyticsSnapshot.make(farmID: farm.id, sheep: allSheep, pens: allPens, weights: weights, weanings: weanings, reproduction: reproduction, offspring: offspring, removals: removals, transfers: transfers, memberships: memberships, feeds: feeds, feedLines: feedLines)
    }

    var body: some View {
        List {
            if !pen.note.isEmpty { Section("说明") { Text(pen.note) } }
            if let herdInsight {
                Section(herdInsight.title) {
                    Text(herdInsight.summary)
                    ForEach(herdInsight.details, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                }
            } else {
                Section { ProgressView("正在计算圈舍分析") }
            }
            Section("当前羊只") {
                if sheep.isEmpty { Text("当前没有在场羊只").foregroundStyle(.secondary) }
                ForEach(sheep, id: \.id) { item in Text(item.earTag) }
            }
        }
        .navigationTitle(pen.name)
        .onAppear(perform: refreshInsight)
        .onChange(of: analyticsSourceRevision) { _, _ in refreshInsight() }
    }

    private func refreshInsight() {
        let snapshot = makeAnalyticsSnapshot()
        let penID = pen.id
        Task {
            herdInsight = await Task.detached(priority: .userInitiated) {
                SheepAnalyticsEngine.penHerd(penID: penID, snapshot: snapshot)
            }.value
        }
    }
}

struct AddSheepView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]

    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()

    @State private var earTag = ""
    @State private var breed = "湖羊"
    @State private var sex = SheepSex.ewe
    @State private var penID: UUID?
    @State private var occurredAt = Date.now
    @State private var birthAt: Date?
    @State private var note = ""
    @State private var errorMessage: String?

    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }

    var body: some View {
        Form {
            Section("基础信息") {
                TextField("耳号", text: $earTag)
                TextField("品种", text: $breed)
                Picker("性别", selection: $sex) { ForEach(SheepSex.allCases, id: \.self) { Text($0.displayName).tag($0) } }
            }
            Section("发生时间") {
                DatePicker("入场时间", selection: $occurredAt)
                Toggle("记录出生日期", isOn: Binding(get: { birthAt != nil }, set: { birthAt = $0 ? occurredAt : nil }))
                if let birthAt { DatePicker("出生日期", selection: Binding(get: { birthAt }, set: { self.birthAt = $0 }), displayedComponents: .date) }
            }
            Section("圈舍") {
                Picker("当前圈舍", selection: $penID) {
                    Text("暂不分圈").tag(UUID?.none)
                    ForEach(farmPens, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            Section("备注") { TextField("可选", text: $note, axis: .vertical).lineLimit(2...4) }
        }
        .navigationTitle("新建羊只")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
        }
        .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        do {
            try commandService.execute(.addSheep(earTag: earTag, breed: breed, sex: sex, penID: penID, occurredAt: occurredAt, birthAt: birthAt, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct AddPenView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var name = ""
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("圈舍名称", text: $name)
            TextField("说明", text: $note, axis: .vertical).lineLimit(2...4)
        }
        .navigationTitle("新建圈舍")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
        }
        .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        do {
            try commandService.execute(.createPen(name: name, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
