import SwiftData
import SwiftUI

private func feedNumberText(_ value: Double) -> String { Decimal(value).stableText }

struct FeedingStartView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    let account: AccountProfile
    let farm: FarmRecord
    @State private var isFeedEntryPresented = false
    @State private var overview = FeedingOverviewSnapshot.empty
    @State private var isLoadingOverview = true
    @State private var overviewError: String?
    @State private var overviewRevision = 0

    private var overviewTaskID: String {
        "\(farm.id.uuidString.lowercased()):\(overviewRevision)"
    }

    var body: some View {
        List {
            Section("今日概览") {
                LabeledContent("投喂次数") {
                    if isLoadingOverview { Text("—") }
                    else { Text("\(overview.todayFeedCount)次") }
                }
                LabeledContent("投料量") {
                    if isLoadingOverview { Text("—") }
                    else { Text("\(FeedAnalysisNumberFormatter.total(overview.todayKilograms)) kg") }
                }
                LabeledContent("待盘槽") {
                    if isLoadingOverview { Text("—") }
                    else { Text("\(overview.pendingTroughCount)项") }
                }
                if isLoadingOverview {
                    ProgressView("正在汇总投喂记录")
                        .font(.footnote)
                } else if let overviewError {
                    Text("汇总失败：\(overviewError)")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Text("投喂、配方和库存都以全舍公斤数保存；每只羊的数据只在营养和采食分析中展示。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("TMR") {
                NavigationLink { TMRFeedingEntryView(account: account, farm: farm) } label: { Label("记录 TMR 投喂", systemImage: "arrow.right.circle") }
                NavigationLink { TMRBatchProductionView(account: account, farm: farm) } label: { Label("制作 TMR", systemImage: "takeoutbag.and.cup.and.straw") }
                NavigationLink { TMRBatchLibraryView(account: account, farm: farm) } label: { Label("TMR 批次", systemImage: "list.bullet.rectangle") }
                NavigationLink { TMRMonitoringView(account: account, farm: farm) } label: { Label("TMR 监控", systemImage: "chart.bar.doc.horizontal") }
                NavigationLink { TMRFeedingPlanLibraryView(account: account, farm: farm) } label: { Label("TMR 投喂计划", systemImage: "calendar") }
                NavigationLink { TMRFormulaLibraryView(account: account, farm: farm) } label: { Label("TMR 配方", systemImage: "list.bullet.clipboard") }
            }
            Section("直接投喂与盘槽") {
                NavigationLink { FeedEntryView(account: account, farm: farm) } label: { Label("直接投喂", systemImage: "plus.circle") }
                NavigationLink { FeedTroughObservationEntryView(account: account, farm: farm) } label: { Label("记录盘槽", systemImage: "scalemass") }
            }
            Section("分析与历史") {
                NavigationLink { FarmAnalyticsView(farm: farm) } label: { Label("采食营养分析", systemImage: "chart.bar.xaxis") }
                NavigationLink { FeedHistoryView(account: account, farm: farm) } label: { Label("投喂与盘槽历史", systemImage: "clock.arrow.circlepath") }
            }
            Section("基础资料") {
                NavigationLink { IngredientLibraryView(account: account, farm: farm) } label: { Label("原料库与库存", systemImage: "shippingbox") }
            }
        }
        .navigationTitle("投喂")
        .sheet(isPresented: $isFeedEntryPresented, onDismiss: refreshOverview) {
            NavigationStack { FeedEntryView(account: account, farm: farm) }
        }
        .task(id: overviewTaskID) { await loadOverview() }
        .onReceive(NotificationCenter.default.publisher(for: CloudRuntimeNotification.syncWake)) { notification in
            guard CloudRuntimeNotification.farmID(from: notification) == farm.id else { return }
            refreshOverview()
        }
        .onAppear(perform: presentIntentEntryIfNeeded)
        .onChange(of: session.pendingRecordEntry) { _, _ in presentIntentEntryIfNeeded() }
    }

    @MainActor
    private func loadOverview() async {
        isLoadingOverview = true
        overviewError = nil
        do {
            overview = try await FeedingOverviewSnapshotActor(container: modelContext.container)
                .load(farmID: farm.id)
            try Task.checkCancellation()
            isLoadingOverview = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            overviewError = "汇总失败：\(error.localizedDescription)"
            isLoadingOverview = false
        }
    }

    private func refreshOverview() {
        overviewRevision &+= 1
    }

    private func presentIntentEntryIfNeeded() {
        guard session.pendingRecordEntry == .feed else { return }
        session.pendingRecordEntry = nil
        isFeedEntryPresented = true
    }
}

struct IngredientLibraryView: View {
    @Query(sort: \FeedIngredientRecord.name) private var ingredients: [FeedIngredientRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @State private var isAdding = false
    @State private var isAddingMixture = false
    @State private var isOpeningSystemLibrary = false
    @State private var searchText = ""

    private var visibleIngredients: [FeedIngredientRecord] {
        ingredients.filter {
            $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive &&
            (searchText.isEmpty || $0.name.localizedStandardContains(searchText) || $0.category.localizedStandardContains(searchText))
        }
    }

    var body: some View {
        List {
            if visibleIngredients.isEmpty {
                ContentUnavailableView("还没有匹配原料", systemImage: "shippingbox", description: Text("可从 eSheepPlus 系统库加入，也可以创建自定义原料。"))
            } else {
                ForEach(visibleIngredients, id: \.id) { ingredient in
                    NavigationLink { IngredientDetailView(account: account, farm: farm, ingredient: ingredient) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(ingredient.name).font(.headline)
                                Spacer()
                                Text(LocalizedStringKey(ingredient.kind.displayName)).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 0) {
                                if !ingredient.category.isEmpty {
                                    Text(verbatim: ingredient.category)
                                }
                                if !ingredient.category.isEmpty { Text(" · ") }
                                Text("单位")
                                Text(verbatim: "：\(ingredient.unit)")
                                if let dryMatter = ingredient.nutrients.dryMatter {
                                    Text(verbatim: " · DM \(feedNumberText(dryMatter))%")
                                }
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索原料名称或类别")
        .navigationTitle("原料库")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { isOpeningSystemLibrary = true } label: { Image(systemName: "books.vertical") }
                Button { isAddingMixture = true } label: { Image(systemName: "circle.grid.2x2") }
                Button { isAdding = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $isAdding) { NavigationStack { AddIngredientView(account: account, farm: farm) } }
        .sheet(isPresented: $isAddingMixture) { NavigationStack { AddMixtureIngredientView(account: account, farm: farm) } }
        .sheet(isPresented: $isOpeningSystemLibrary) { NavigationStack { SystemIngredientLibraryView(account: account, farm: farm) } }
        .farmExcelImport(account: account, farm: farm, sheets: ["饲料原料"])
    }
}

private struct AddIngredientView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var name = ""
    @State private var category = ""
    @State private var unit = "千克"
    @State private var dryMatter = ""
    @State private var crudeProtein = ""
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("原料名称", text: $name)
                TextField("类别（可选）", text: $category)
                TextField("计量单位", text: $unit)
            }
            Section("营养快照（可选）") {
                TextField("干物质 DM（%）", text: $dryMatter).keyboardType(.decimalPad)
                TextField("粗蛋白 CP（%）", text: $crudeProtein).keyboardType(.decimalPad)
                Text("未填写的参数会保持缺失，不按 0 参与营养计算。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
        }
        .navigationTitle("新增自定义原料")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        let nutrients = FeedNutrients(dryMatter: Double(dryMatter), crudeProtein: Double(crudeProtein))
        let draft = FeedIngredientDraft(name: name, unit: unit, category: category, dryMatterText: dryMatter.isEmpty ? nil : dryMatter, nutrientSnapshotJSON: FeedNutritionCodec.encode(nutrients), kind: .custom, note: note)
        do {
            try commandService.execute(.saveFeedIngredient(draft), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct MixtureLineInput: Identifiable, Hashable {
    let id = UUID()
    var ingredientID: UUID?
    var sharePercent: String

    init(ingredientID: UUID? = nil, sharePercent: String = "") {
        self.ingredientID = ingredientID
        self.sharePercent = sharePercent
    }
}

private struct AddMixtureIngredientView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FeedIngredientRecord.name) private var ingredients: [FeedIngredientRecord]
    @Query(sort: \FeedIngredientBatchRecord.updatedAt, order: .reverse) private var batches: [FeedIngredientBatchRecord]
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var name = ""
    @State private var lines = [MixtureLineInput(), MixtureLineInput()]
    @State private var note = ""
    @State private var errorMessage: String?

    private var farmIngredients: [FeedIngredientRecord] {
        ingredients.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive }
    }

    private var mixtureComponents: [FeedMixtureComponent] {
        lines.compactMap { line in
            guard let ingredientID = line.ingredientID,
                  let ingredient = farmIngredients.first(where: { $0.id == ingredientID }),
                  let share = Double(line.sharePercent), share > 0 else { return nil }
            return FeedMixtureComponent(
                ingredientID: ingredient.id,
                ingredientName: ingredient.name,
                sharePercent: share,
                nutrients: ingredient.nutrients,
                pricePerKilogram: latestPrice(for: ingredient.id)
            )
        }
    }

    private var preview: FeedMixtureResult? { try? FeedMixtureCalculator.calculate(components: mixtureComponents) }

    var body: some View {
        Form {
            Section("混合料") {
                TextField("混合料名称", text: $name)
                Text("比例按百分比录入，合计必须为 100%；保存后营养参数和组成都是独立快照。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("原料比例") {
                ForEach($lines) { $line in
                    HStack {
                        Picker("原料", selection: $line.ingredientID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(farmIngredients, id: \.id) { ingredient in
                                Text(ingredient.name).tag(UUID?.some(ingredient.id))
                            }
                        }
                        TextField("%", text: $line.sharePercent)
                            .keyboardType(.decimalPad)
                            .frame(width: 72)
                    }
                    .swipeActions {
                        if lines.count > 2 {
                            Button(role: .destructive) { lines.removeAll { $0.id == line.id } } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                Button("添加一种原料") { lines.append(MixtureLineInput()) }
            }
            if let preview {
                Section("营养与价格预览") {
                    LabeledContent("干物质 DM", value: preview.nutrients.dryMatter.map { "\(feedNumberText($0))%" } ?? "缺失")
                    LabeledContent("粗蛋白 CP", value: preview.nutrients.crudeProtein.map { "\(feedNumberText($0))%" } ?? "缺失")
                    LabeledContent("ME", value: preview.nutrients.meMJPerKgDM.map { "\(feedNumberText($0)) MJ/kg DM" } ?? "缺失")
                    LabeledContent("加权单价", value: preview.pricePerKilogram.map { "\(feedNumberText($0)) 元/kg" } ?? "缺少批次单价")
                }
            } else if !mixtureComponents.isEmpty {
                Text("请至少选择两种原料，并让比例合计为 100%。")
                    .font(.footnote).foregroundStyle(.orange)
            }
            TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
        }
        .navigationTitle("新增混合料")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func latestPrice(for ingredientID: UUID) -> Double? {
        guard let batch = batches.first(where: {
            $0.farmID == farm.id && $0.ingredientID == ingredientID && $0.deletedAt == nil && $0.isActive
        }), let value = Decimal.stable(batch.pricePerKilogramText) else { return nil }
        return NSDecimalNumber(decimal: value).doubleValue
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请输入混合料名称。"
            return
        }
        do {
            let result = try FeedMixtureCalculator.calculate(components: mixtureComponents)
            let draft = FeedIngredientDraft(
                name: name,
                unit: "千克",
                category: "混合料",
                dryMatterText: result.nutrients.dryMatter.map(feedNumberText),
                nutrientSnapshotJSON: FeedNutritionCodec.encode(result.nutrients),
                kind: .mixture,
                mixtureComponentsJSON: FeedMixtureCodec.encode(result.components),
                note: note
            )
            try commandService.execute(.saveFeedIngredient(draft), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct SystemIngredientLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var ingredients: [FeedIngredientRecord]
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var templates: [FeedIngredientTemplate] = []
    @State private var category = "全部"
    @State private var searchText = ""
    @State private var errorMessage: String?

    private var categories: [String] { ["全部"] + Array(Set(templates.map(\.category))).sorted() }
    private var visibleTemplates: [FeedIngredientTemplate] {
        templates.filter {
            (category == "全部" || $0.category == category) &&
            (searchText.isEmpty || $0.name.localizedStandardContains(searchText) || $0.code.localizedStandardContains(searchText) || $0.category.localizedStandardContains(searchText))
        }
    }

    var body: some View {
        List {
            if templates.isEmpty {
                ContentUnavailableView("系统原料库不可用", systemImage: "exclamationmark.triangle", description: Text("请检查应用资源是否已打包。"))
            } else {
                Section {
                    Picker("类别", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }
                }
                Section("eSheepPlus 系统库 · \(templates.count) 条") {
                    ForEach(visibleTemplates) { template in
                        let isAdded = isTemplateAdded(template)
                        Button { add(template) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(template.name).foregroundStyle(.primary)
                                    let dmText = template.nutrients.dryMatter.map(feedNumberText) ?? "缺失"
                                    Text("\(template.code) · \(template.category) · DM \(dmText)%")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundStyle(isAdded ? Color.green : Color.accentColor)
                            }
                        }
                        .disabled(isAdded)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "名称、编号或类别")
        .navigationTitle("系统原料库")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        .onAppear { templates = (try? FeedTemplateLibrary.load()) ?? [] }
        .recordErrorAlert($errorMessage)
    }

    private func add(_ template: FeedIngredientTemplate) {
        let draft = FeedIngredientDraft(name: template.name, unit: "千克", category: template.category, dryMatterText: template.nutrients.dryMatter.map(feedNumberText), nutrientSnapshotJSON: FeedNutritionCodec.encode(template.nutrients), kind: .system, sourceTemplateID: template.id, sourceTemplateCode: template.code, note: "来自 eSheepPlus 系统原料库；加入后保存独立营养快照。")
        do {
            try commandService.execute(.saveFeedIngredient(draft), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
        } catch { errorMessage = error.localizedDescription }
    }

    private func isTemplateAdded(_ template: FeedIngredientTemplate) -> Bool {
        let farmID = farm.id
        let templateID = template.id
        return ingredients.contains { ingredient in
            ingredient.farmID == farmID && ingredient.deletedAt == nil && ingredient.sourceTemplateID == templateID
        }
    }
}

struct IngredientDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FeedIngredientBatchRecord.batchName) private var batches: [FeedIngredientBatchRecord]
    let account: AccountProfile
    let farm: FarmRecord
    let ingredient: FeedIngredientRecord
    @State private var isAddingBatch = false

    private var farmBatches: [FeedIngredientBatchRecord] { batches.filter { $0.farmID == farm.id && $0.ingredientID == ingredient.id && $0.deletedAt == nil && $0.isActive } }

    var body: some View {
        List {
            Section("原料快照") {
                LabeledContent("来源", value: ingredient.kind.displayName)
                if let code = ingredient.sourceTemplateCode { LabeledContent("系统编号", value: code) }
                ForEach(FeedNutrientKey.allCases, id: \.self) { key in
                    if let value = ingredient.nutrients.value(for: key) {
                        LabeledContent(key.displayName, value: "\(feedNumberText(value)) \(key.unit)")
                    }
                }
                if let extra = ingredient.nutrients.extra, !extra.isEmpty {
                    ForEach(extra.keys.sorted(), id: \.self) { key in
                        if let value = extra[key] { LabeledContent(key, value: feedNumberText(value)) }
                    }
                }
            }
            if ingredient.kind == .mixture {
                let components = FeedMixtureCodec.decode(ingredient.mixtureComponentsJSON)
                Section("混合料组成快照") {
                    if components.isEmpty {
                        Text("组成快照缺失").foregroundStyle(.secondary)
                    } else {
                        ForEach(components) { component in
                            HStack {
                                Text(verbatim: component.ingredientName)
                                Spacer()
                                Text("\(feedNumberText(component.sharePercent))%")
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            Section("批次与库存") {
                if farmBatches.isEmpty { Text("还没有批次。购入量、包装说明和可投喂库存需要在批次中分别录入。") .foregroundStyle(.secondary) }
                ForEach(farmBatches, id: \.id) { batch in
                    NavigationLink { FeedBatchDetailView(account: account, farm: farm, ingredient: ingredient, batch: batch) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(batch.batchName.isEmpty ? "未命名批次" : batch.batchName).font(.headline)
                            Text("\(batch.packagingKind.displayName) · 购入 \(batch.purchasedKilogramsText ?? "未记录") kg")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(stockText(batch)).font(.subheadline).foregroundStyle(stockBalance(for: batch) == nil ? .orange : .secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(ingredient.name)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { isAddingBatch = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $isAddingBatch) { NavigationStack { FeedBatchEditorView(account: account, farm: farm, ingredient: ingredient) } }
    }

    private func stockBalance(for batch: FeedIngredientBatchRecord) -> Decimal? {
        try? FeedStockLedger.balance(for: batch, context: modelContext)
    }

    private func stockText(_ batch: FeedIngredientBatchRecord) -> String {
        stockBalance(for: batch).map { "库存 \($0.stableText) kg" } ?? "库存基线待补录"
    }
}

private struct FeedBatchEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    let ingredient: FeedIngredientRecord
    private let commandService = FarmCommandService()
    @State private var batchName = ""
    @State private var purchaseDate = Date.now
    @State private var supplier = ""
    @State private var storageLocation = ""
    @State private var price = "0"
    @State private var purchased = ""
    @State private var packaging: FeedPackagingKind = .bulk
    @State private var packageCount = ""
    @State private var nominalPackageWeight = ""
    @State private var stockKilograms = ""
    @State private var stockConfirmed = false
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("购入与批次") {
                TextField("批次名称", text: $batchName)
                DatePicker("购入日期", selection: $purchaseDate, displayedComponents: .date)
                TextField("购入量（kg，可选）", text: $purchased).keyboardType(.decimalPad)
                TextField("单价（元/kg）", text: $price).keyboardType(.decimalPad)
                TextField("供应商", text: $supplier)
                TextField("存放位置", text: $storageLocation)
            }
            Section("包装说明（不自动换算为库存）") {
                Picker("形态", selection: $packaging) { ForEach(FeedPackagingKind.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) } }
                if packaging != .bulk {
                    TextField("包装/捆数量（说明）", text: $packageCount).keyboardType(.decimalPad)
                    TextField("标称每袋/捆重量 kg（说明）", text: $nominalPackageWeight).keyboardType(.decimalPad)
                }
                Text("草捆重量不统一、玉米可能散装；包装数量和标称重量只作说明，实际库存必须单独录入公斤。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("可投喂库存基线") {
                TextField("当前实际库存（kg，可先不填）", text: $stockKilograms).keyboardType(.decimalPad)
                Toggle("这个公斤数已核实", isOn: $stockConfirmed)
                Text("不填库存基线的批次可以保存，但在补录库存前不能用于新投喂。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
        }
        .navigationTitle("新建批次")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        let draft = FeedBatchDraft(ingredientID: ingredient.id, batchName: batchName, purchaseDate: purchaseDate, supplier: supplier, storageLocation: storageLocation, pricePerKilogramText: price, purchasedKilogramsText: purchased.isEmpty ? nil : purchased, packagingKind: packaging, packageCountText: packageCount.isEmpty ? nil : packageCount, nominalPackageKilogramsText: nominalPackageWeight.isEmpty ? nil : nominalPackageWeight, stockWeightConfirmed: stockConfirmed, initialKilogramsText: stockKilograms.isEmpty ? nil : stockKilograms, remainingKilogramsText: stockKilograms.isEmpty ? nil : stockKilograms, note: note)
        do {
            try commandService.execute(.saveFeedBatch(draft), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct FeedBatchDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var transactions: [FeedStockTransactionRecord]
    @Query(sort: \FeedStockCountRecord.occurredAt, order: .reverse) private var counts: [FeedStockCountRecord]
    let account: AccountProfile
    let farm: FarmRecord
    let ingredient: FeedIngredientRecord
    let batch: FeedIngredientBatchRecord
    @State private var isCounting = false
    @State private var isAdjusting = false

    private var farmTransactions: [FeedStockTransactionRecord] { transactions.filter { $0.farmID == farm.id && $0.ingredientBatchID == batch.id && $0.deletedAt == nil }.sorted { $0.occurredAt > $1.occurredAt } }
    private var farmCounts: [FeedStockCountRecord] { counts.filter { $0.farmID == farm.id && $0.ingredientBatchID == batch.id && $0.deletedAt == nil } }
    private var balance: Decimal? { try? FeedStockLedger.balance(for: batch, context: modelContext) }

    var body: some View {
        List {
            Section("库存") {
                LabeledContent("购入量", value: "\(batch.purchasedKilogramsText ?? "未记录") kg")
                if let balance { LabeledContent("账面库存", value: "\(balance.stableText) kg") }
                else { Text("尚未设置公斤库存基线，不能投喂或盘库校正。").foregroundStyle(.orange) }
                Text("\(batch.packagingKind.displayName) · 包装数量 \(batch.packageCountText ?? "未记录") · 标称重量 \(batch.nominalPackageKilogramsText ?? "未记录") kg")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink("盘库/登记散装料暂未称量") { FeedStockCountView(account: account, farm: farm, batch: batch) }
                NavigationLink("登记入库或库存调整") { FeedStockAdjustmentView(account: account, farm: farm, batch: batch) }
            }
            Section("盘库记录") {
                if farmCounts.isEmpty { Text("还没有盘库记录。散装料不能称重时，可以记录“暂未称量”，不会伪造公斤差异。") .foregroundStyle(.secondary) }
                ForEach(farmCounts, id: \.id) { count in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LocalizedStringKey(count.method.displayName)).font(.headline)
                        if let actual = count.actualKilogramsText {
                            Text("账面 \(count.bookBalanceText) kg → 盘点 \(actual) kg · 差异 \(count.differenceText ?? "—") kg")
                        } else {
                            Text("账面 \(count.bookBalanceText) kg · 实际重量待补录")
                        }
                        Text(count.occurredAt, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("库存流水") {
                ForEach(farmTransactions, id: \.id) { transaction in
                    HStack {
                        Text(stockTransactionTitle(transaction.kind))
                        Spacer()
                        Text("\(transaction.signedQuantity.stableText) kg")
                            .foregroundStyle(transaction.signedQuantity < 0 ? .red : .secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
        .navigationTitle(batch.batchName.isEmpty ? ingredient.name : batch.batchName)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { isAdjusting = true } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                Button { isCounting = true } label: { Image(systemName: "checklist") }
            }
        }
        .sheet(isPresented: $isCounting) { NavigationStack { FeedStockCountView(account: account, farm: farm, batch: batch) } }
        .sheet(isPresented: $isAdjusting) { NavigationStack { FeedStockAdjustmentView(account: account, farm: farm, batch: batch) } }
    }

    private func stockTransactionTitle(_ kind: FeedStockTransactionKind) -> String {
        switch kind {
        case .openingBalance: "期初库存"
        case .receipt: "入库"
        case .consumption: "投喂扣减"
        case .adjustment: "盘库/手工调整"
        case .reversal: "删除投喂冲回"
        case .conflict: "并发冲突"
        }
    }
}

private struct FeedStockAdjustmentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    let batch: FeedIngredientBatchRecord
    private let commandService = FarmCommandService()
    @State private var kind: FeedStockTransactionKind = .receipt
    @State private var quantity = ""
    @State private var occurredAt = Date.now
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("库存流水") {
                Picker("类型", selection: $kind) {
                    Text("入库").tag(FeedStockTransactionKind.receipt)
                    Text("盘库后手工调整").tag(FeedStockTransactionKind.adjustment)
                }
                TextField(kind == .receipt ? "入库量（kg）" : "调整量（kg，可正可负）", text: $quantity).keyboardType(.numbersAndPunctuation)
                DatePicker("发生时间", selection: $occurredAt, in: ...Date.now)
                TextField("原因/备注", text: $note, axis: .vertical).lineLimit(2...4)
            }
            Text("购入量记录在批次档案中；这里记录实际进入该批次库存的公斤流水。散装料仍不能用包装标称重量代替。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("库存流水")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        do {
            try commandService.execute(.adjustFeedStock(batchID: batch.id, kind: kind, quantityText: quantity, occurredAt: occurredAt, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct FeedStockCountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    let batch: FeedIngredientBatchRecord
    private let commandService = FarmCommandService()
    @State private var method: FeedStockCountMethod = .notMeasured
    @State private var actualKilograms = ""
    @State private var occurredAt = Date.now
    @State private var note = ""
    @State private var errorMessage: String?

    private var bookBalance: Decimal? { try? FeedStockLedger.balance(for: batch, context: modelContext) }

    var body: some View {
        Form {
            Section("盘库对象") {
                LabeledContent("批次", value: batch.batchName.isEmpty ? "未命名批次" : batch.batchName)
                LabeledContent("账面库存", value: bookBalance.map { "\($0.stableText) kg" } ?? "待补录基线")
            }
            Section("盘库方式") {
                Picker("方式", selection: $method) { ForEach(FeedStockCountMethod.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) } }
                if method == .notMeasured {
                    Text("适用于散装玉米、草料等当前无法称重的库存。保存后只留下待核对记录，账面公斤数不变。")
                        .font(.footnote).foregroundStyle(.orange)
                } else {
                    TextField(method == .volumeEstimate ? "估算剩余量（kg）" : "实际剩余量（kg）", text: $actualKilograms).keyboardType(.decimalPad)
                    if method == .packagedCount {
                        Text("仅适用于每袋/包重量确实一致的情况；请输入换算后的实际 kg。草捆重量不一致时不要用此方式。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if method.isEstimated { Text("这是体积密度估算，会在盘库记录中标明估算。") .font(.footnote).foregroundStyle(.orange) }
                }
                DatePicker("盘库时间", selection: $occurredAt)
            }
            TextField("说明（如：散装料仓，待下次过磅）", text: $note, axis: .vertical).lineLimit(2...4)
        }
        .navigationTitle("盘库")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
        .onChange(of: method) { _, newValue in if newValue == .notMeasured { actualKilograms = "" } }
    }

    private func save() {
        let actual = method == .notMeasured ? nil : (actualKilograms.isEmpty ? nil : actualKilograms)
        do {
            try commandService.execute(.countFeedStock(countID: UUID(), batchID: batch.id, actualKilogramsText: actual, method: method, occurredAt: occurredAt, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct RecipeLibraryView: View {
    @Query(sort: \FeedRecipeRecord.name) private var recipes: [FeedRecipeRecord]
    @Query private var components: [FeedRecipeComponentRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @State private var isAdding = false

    private var farmRecipes: [FeedRecipeRecord] { recipes.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }

    var body: some View {
        List {
            if farmRecipes.isEmpty {
                ContentUnavailableView("还没有配方", systemImage: "list.bullet.rectangle", description: Text("配方会保存批次、营养和价格快照。"))
            } else {
                ForEach(farmRecipes, id: \.id) { recipe in
                    NavigationLink { FeedRecipeEditorView(account: account, farm: farm, recipe: recipe) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recipe.name).font(.headline)
                            Text("\(components.filter { $0.farmID == farm.id && $0.recipeID == recipe.id && $0.deletedAt == nil }.count) 种原料 · \(recipe.headCount.map(String.init) ?? "未设") 只设计羊数")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("配方")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { isAdding = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $isAdding) { NavigationStack { FeedRecipeEditorView(account: account, farm: farm) } }
        .farmExcelImport(account: account, farm: farm, sheets: ["饲料配方", "配方组成"])
    }
}

private struct RecipeLineInput: Identifiable, Hashable {
    let id: UUID
    var ingredientID: UUID?
    var batchID: UUID?
    var kilogramsText: String

    init(id: UUID = UUID(), ingredientID: UUID? = nil, batchID: UUID? = nil, kilogramsText: String = "") {
        self.id = id
        self.ingredientID = ingredientID
        self.batchID = batchID
        self.kilogramsText = kilogramsText
    }
}

private struct FeedRecipeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FeedIngredientRecord.name) private var ingredients: [FeedIngredientRecord]
    @Query(sort: \FeedIngredientBatchRecord.batchName) private var batches: [FeedIngredientBatchRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query private var storedComponents: [FeedRecipeComponentRecord]
    let account: AccountProfile
    let farm: FarmRecord
    let recipe: FeedRecipeRecord?
    private let commandService = FarmCommandService()
    @State private var name: String
    @State private var stage: FeedRecipeStage
    @State private var targetPenID: UUID?
    @State private var headCountText: String
    @State private var note: String
    @State private var rows: [RecipeLineInput] = []
    @State private var didLoad = false
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, recipe: FeedRecipeRecord? = nil) {
        self.account = account
        self.farm = farm
        self.recipe = recipe
        _name = State(initialValue: recipe?.name ?? "")
        _stage = State(initialValue: recipe?.stage ?? .custom)
        _targetPenID = State(initialValue: recipe?.targetPenID)
        _headCountText = State(initialValue: recipe?.headCount.map(String.init) ?? "")
        _note = State(initialValue: recipe?.note ?? "")
    }

    private var farmIngredients: [FeedIngredientRecord] { ingredients.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var farmBatches: [FeedIngredientBatchRecord] { batches.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var validComponents: [(row: RecipeLineInput, ingredient: FeedIngredientRecord, batch: FeedIngredientBatchRecord)] {
        rows.compactMap { row in
            guard let ingredientID = row.ingredientID, let batchID = row.batchID, let ingredient = farmIngredients.first(where: { $0.id == ingredientID }), let batch = farmBatches.first(where: { $0.id == batchID && $0.ingredientID == ingredientID }), let kilograms = Double(row.kilogramsText), kilograms > 0 else { return nil }
            return (row, ingredient, batch)
        }
    }
    private var nutritionSummary: FeedRecipeNutritionSummary {
        FeedRecipeNutritionSummary.calculate(components: validComponents.map { value in
            FeedNutritionComponent(ingredientID: value.ingredient.id, ingredientName: value.ingredient.name, freshKilograms: Double(value.row.kilogramsText) ?? 0, pricePerKilogram: Double(value.batch.pricePerKilogramText), nutrients: value.ingredient.nutrients)
        })
    }

    var body: some View {
        Form {
            Section("配方信息") {
                TextField("配方名称", text: $name)
                Picker("生产阶段", selection: $stage) { ForEach(FeedRecipeStage.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) } }
                Picker("适用圈舍", selection: $targetPenID) { Text("不限定圈舍").tag(UUID?.none); ForEach(farmPens, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }
                TextField("设计羊数", text: $headCountText).keyboardType(.numberPad)
            }
            Section("原料批次") {
                ForEach($rows) { $row in
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("原料", selection: $row.ingredientID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(farmIngredients, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        Picker("批次", selection: $row.batchID) {
                            Text("请选择库存批次").tag(UUID?.none)
                            ForEach(farmBatches.filter { $0.ingredientID == row.ingredientID }, id: \.id) { batch in
                                Text("\(batch.batchName.isEmpty ? "未命名" : batch.batchName) · \(stockText(batch))").tag(UUID?.some(batch.id))
                            }
                        }
                        TextField("全舍每日鲜重 kg", text: $row.kilogramsText).keyboardType(.decimalPad)
                    }
                    .swipeActions { Button(role: .destructive) { rows.removeAll { $0.id == row.id } } label: { Label("删除", systemImage: "trash") } }
                }
                Button { rows.append(RecipeLineInput()) } label: { Label("添加原料批次", systemImage: "plus.circle") }
            }
            Section("营养与成本预览") {
                LabeledContent("全舍鲜重", value: "\(feedNumberText(nutritionSummary.asFedKilograms)) kg/日")
                if let dm = nutritionSummary.dryMatterKilograms { LabeledContent("干物质", value: "\(feedNumberText(dm)) kg/日") }
                if let cost = nutritionSummary.cost { LabeledContent("成本", value: "\(feedNumberText(cost)) 元/日") }
                ForEach(FeedNutrientKey.allCases, id: \.self) { key in
                    if let value = nutritionSummary.nutrients.value(for: key) {
                        VStack(alignment: .leading, spacing: 2) {
                            LabeledContent(key.displayName, value: "\(feedNumberText(value)) \(key.unit)")
                            if let coverage = nutritionSummary.coverage[key], !coverage.isComplete {
                                Text("覆盖率 \(feedNumberText(coverage.coverage * 100))% · 缺失：\(coverage.missingIngredientNames.joined(separator: "、"))")
                                    .font(.caption).foregroundStyle(.orange)
                            } else if nutritionSummary.coverage[key]?.inferred == true {
                                Text("由其他能量参数推算").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    } else if let coverage = nutritionSummary.coverage[key], !coverage.isComplete {
                        Text("\(key.displayName)：未完整计算 · 覆盖率 \(feedNumberText(coverage.coverage * 100))% · 缺失：\(coverage.missingIngredientNames.joined(separator: "、"))")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                ForEach(nutritionSummary.extraCoverage.keys.sorted(), id: \.self) { key in
                    let coverage = nutritionSummary.extraCoverage[key]
                    if let value = nutritionSummary.nutrients.extra?[key] {
                        LabeledContent(key, value: feedNumberText(value))
                    } else {
                        Text("\(key)：覆盖率 \(feedNumberText((coverage?.coverage ?? 0) * 100))% · 缺失 \(coverage?.missingIngredientNames.joined(separator: "、") ?? "")")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let perHead = nutritionSummary.perHead(headCount: Int(headCountText)) {
                    Text("每只每天：鲜重 \(feedNumberText(perHead.asFedKilograms)) kg · 干物质 \(perHead.dryMatterKilograms.map(feedNumberText) ?? "—") kg")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
        }
        .navigationTitle(recipe == nil ? "新建配方" : "编辑配方")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
        .onAppear { loadExistingRowsIfNeeded() }
    }

    private func stockText(_ batch: FeedIngredientBatchRecord) -> String {
        guard let value = try? FeedStockLedger.balance(for: batch, context: modelContext) else { return "待补录库存" }
        return "库存 \(value.stableText)kg"
    }

    private func loadExistingRowsIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let recipe else { return }
        rows = storedComponents.filter { $0.farmID == farm.id && $0.recipeID == recipe.id && $0.deletedAt == nil }.map { RecipeLineInput(id: $0.id, ingredientID: $0.ingredientID, batchID: $0.ingredientBatchID, kilogramsText: $0.kilogramsText) }
    }

    private func save() {
        guard !validComponents.isEmpty else { errorMessage = "至少添加一条完整的原料批次和用量。"; return }
        guard validComponents.count == rows.count else { errorMessage = "请补全每一行的原料、库存批次和用量。"; return }
        let components = validComponents.map { value in
            FeedRecipeComponentDraft(id: value.row.id, ingredientID: value.ingredient.id, ingredientBatchID: value.batch.id, kilogramsText: value.row.kilogramsText, pricePerKilogramText: value.batch.pricePerKilogramText, nutrientSnapshotJSON: value.ingredient.nutrientSnapshotJSON)
        }
        let targetName = targetPenID.flatMap { penID in farmPens.first(where: { $0.id == penID })?.name }
        let draft = FeedRecipeDraft(id: recipe?.id, name: name, targetPenID: targetPenID, targetPenName: targetName, stage: stage, headCount: Int(headCountText), components: components, note: note)
        do {
            try commandService.execute(.saveFeedRecipe(draft), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct FeedingLineInput: Identifiable, Hashable {
    let id: UUID
    var ingredientID: UUID?
    var batchID: UUID?
    var kilogramsText: String

    init(id: UUID = UUID(), ingredientID: UUID? = nil, batchID: UUID? = nil, kilogramsText: String = "") {
        self.id = id
        self.ingredientID = ingredientID
        self.batchID = batchID
        self.kilogramsText = kilogramsText
    }
}

private struct FeedingPenInput: Identifiable, Hashable {
    let penID: UUID
    var mixtureKilogramsText = ""
    var remainingKilogramsText = ""
    var discardedKilogramsText = ""

    var id: UUID { penID }
}

private struct FeedPenSelectionRow: View {
    let name: String
    let headCount: Int

    var body: some View {
        VStack(alignment: .leading) {
            Text(name).foregroundStyle(.primary)
            Text("当日 \(headCount)只").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FeedPenSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    let pens: [PenRecord]
    let headCountByPen: [UUID: Int]
    @Binding var selection: Set<UUID>

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(pens, id: \.id) { pen in
                    FeedPenSelectionRow(name: pen.name, headCount: headCountByPen[pen.id, default: 0])
                    .tag(pen.id)
                }
            } header: {
                Text("投喂发生日期当天有羊的圈舍")
            } footer: {
                Text("可点击单个圈舍，也可用双指在列表中上下滑动连续选择。")
            }
        }
        .environment(\.editMode, .constant(.active))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == pens.count ? LocalizedStringKey("取消全选") : LocalizedStringKey("全选")) {
                    if selection.count == pens.count {
                        selection.removeAll()
                    } else {
                        selection = Set(pens.map(\.id))
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") {
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
        .navigationTitle("选择圈舍")
    }
}

private enum FeedPenAllocationMethod: String, CaseIterable, Identifiable {
    case perPen = "逐舍填写"
    case averageByHeadCount = "按羊数均分"

    var id: Self { self }
}

private enum FeedMealPeriod: String, CaseIterable, Identifiable {
    case morning = "早"
    case noon = "中"
    case evening = "晚"
    case allDay = "全天"

    var id: Self { self }
}

private struct FeedCountExclusionRow: View {
    let earTag: String
    let detail: Text?
    let isExcluded: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(earTag)
                    .foregroundStyle(.primary)
                if let detail {
                    detail
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isExcluded {
                Label("不计入", systemImage: "minus.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct FeedCountExclusionView: View {
    let pens: [PenRecord]
    let sheepByPen: [UUID: [FeedPenEligibleSheepSnapshot]]
    let recommendedSheepIDs: Set<UUID>
    @Binding var excludedSheepIDs: Set<UUID>

    private var visibleSheepIDs: Set<UUID> { Set(pens.flatMap { sheepByPen[$0.id] ?? [] }.map(\.id)) }
    private var visibleRecommendations: Set<UUID> { recommendedSheepIDs.intersection(visibleSheepIDs) }

    private func recommendedSheep(in pen: PenRecord) -> [FeedPenEligibleSheepSnapshot] {
        (sheepByPen[pen.id] ?? [])
            .filter { item in visibleRecommendations.contains(item.id) }
            .sorted { lhs, rhs in
                lhs.earTag.localizedStandardCompare(rhs.earTag) == .orderedAscending
            }
    }

    private func otherSheep(in pen: PenRecord) -> [FeedPenEligibleSheepSnapshot] {
        (sheepByPen[pen.id] ?? [])
            .filter { item in !visibleRecommendations.contains(item.id) }
            .sorted { lhs, rhs in
                lhs.earTag.localizedStandardCompare(rhs.earTag) == .orderedAscending
            }
    }

    private func toggleExclusion(for sheepID: UUID) {
        if excludedSheepIDs.contains(sheepID) {
            excludedSheepIDs.remove(sheepID)
        } else {
            excludedSheepIDs.insert(sheepID)
        }
    }

    var body: some View {
        List {
            Section {
                Text("勾选后，该羊只不计入本次均分人数，但不会改变羊只所在圈舍和存栏。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                if visibleRecommendations.isEmpty {
                    Text("本次没有出生45日内且尚未断奶的推荐羊只。")
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        excludedSheepIDs.formUnion(visibleRecommendations)
                    } label: {
                        Label("采用全部建议（\(visibleRecommendations.count)只）", systemImage: "sparkles")
                    }

                    ForEach(pens, id: \.id) { pen in
                        ForEach(recommendedSheep(in: pen), id: \.id) { item in
                            Button {
                                toggleExclusion(for: item.id)
                            } label: {
                                FeedCountExclusionRow(
                                    earTag: item.earTag,
                                    detail: Text(verbatim: pen.name + String(localized: " · 出生45日内且未断奶")),
                                    isExcluded: excludedSheepIDs.contains(item.id)
                                )
                            }
                        }
                    }
                }
            } header: {
                Text("建议扣除")
            } footer: {
                Text("推荐仅供确认，不会自动扣除；可逐只选择，也可采用全部建议。")
            }

            ForEach(pens, id: \.id) { pen in
                let otherSheep = otherSheep(in: pen)
                if !otherSheep.isEmpty {
                    Section("\(pen.name) · 其他羊只") {
                        ForEach(otherSheep, id: \.id) { item in
                            Button {
                                toggleExclusion(for: item.id)
                            } label: {
                                FeedCountExclusionRow(
                                    earTag: item.earTag,
                                    detail: nil,
                                    isExcluded: excludedSheepIDs.contains(item.id)
                                )
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("扣除羊只计数")
    }
}

struct FeedEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query(sort: \FeedIngredientRecord.name) private var ingredients: [FeedIngredientRecord]
    @Query(sort: \FeedIngredientBatchRecord.batchName) private var batches: [FeedIngredientBatchRecord]
    @Query(sort: \FeedRecipeRecord.name) private var recipes: [FeedRecipeRecord]
    @Query private var components: [FeedRecipeComponentRecord]
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var penEntries: [FeedingPenInput] = []
    @State private var allocationMethod = FeedPenAllocationMethod.perPen
    @State private var averageLines: [FeedingLineInput] = []
    @State private var excludedSheepIDs: Set<UUID> = []
    @State private var selectedDaySheepByPen: [UUID: [FeedPenEligibleSheepSnapshot]] = [:]
    @State private var recommendedExcludedSheepIDs: Set<UUID> = []
    @State private var isResolvingPenEligibility = true
    @State private var recipeID: UUID?
    @State private var mode = FeedMode.limited
    @State private var occurredAt = Date.now
    @State private var mealPeriod: FeedMealPeriod?
    @State private var note = ""
    @State private var newIngredientID: UUID?
    @State private var newBatchID: UUID?
    @State private var newKilograms = ""
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account
        self.farm = farm
        let farmID = farm.id
        _pens = Query(
            filter: #Predicate<PenRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \PenRecord.name
        )
        _ingredients = Query(
            filter: #Predicate<FeedIngredientRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \FeedIngredientRecord.name
        )
        _batches = Query(
            filter: #Predicate<FeedIngredientBatchRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \FeedIngredientBatchRecord.batchName
        )
        _recipes = Query(
            filter: #Predicate<FeedRecipeRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \FeedRecipeRecord.name
        )
        _components = Query(filter: #Predicate<FeedRecipeComponentRecord> {
            $0.farmID == farmID && $0.deletedAt == nil
        })
    }

    private var selectedDayHeadCountByPen: [UUID: Int] { selectedDaySheepByPen.mapValues(\.count) }
    private var feedPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && (selectedDayHeadCountByPen[$0.id] ?? 0) > 0 } }
    private var farmIngredients: [FeedIngredientRecord] { ingredients.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var farmBatches: [FeedIngredientBatchRecord] { batches.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var newIngredientBatches: [FeedIngredientBatchRecord] { farmBatches.filter { $0.ingredientID == newIngredientID } }
    private var farmRecipes: [FeedRecipeRecord] { recipes.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var selectedRecipe: FeedRecipeRecord? { recipeID.flatMap { id in farmRecipes.first(where: { $0.id == id }) } }
    private var selectedPenIDs: Set<UUID> { Set(penEntries.map(\.penID)) }
    private var selectedDaySheep: [FeedPenEligibleSheepSnapshot] { penEntries.flatMap { selectedDaySheepByPen[$0.penID] ?? [] } }
    private var countedHeadCountByPen: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: penEntries.map { entry in
            (entry.penID, (selectedDaySheepByPen[entry.penID] ?? []).filter { !excludedSheepIDs.contains($0.id) }.count)
        })
    }
    private var totalCountedHeadCount: Int { countedHeadCountByPen.values.reduce(0, +) }
    private var mixtureCompositionKilograms: Decimal { averageLines.reduce(0) { $0 + (Decimal.stable($1.kilogramsText) ?? 0) } }
    private var totalKilograms: Decimal {
        allocationMethod == .perPen
            ? penEntries.reduce(0) { $0 + (Decimal.stable($1.mixtureKilogramsText) ?? 0) }
            : mixtureCompositionKilograms
    }

    private var penSelection: Binding<Set<UUID>> {
        Binding(
            get: { Set(penEntries.map(\.penID)) },
            set: { updateSelectedPens($0) }
        )
    }

    var body: some View {
        Form {
            Section("投喂对象") {
                if isResolvingPenEligibility {
                    ProgressView("正在确认投喂日期的圈舍存栏")
                } else if feedPens.isEmpty {
                    ContentUnavailableView("当日没有可投喂圈舍", systemImage: "sheep", description: Text("只有投喂发生日期当天有羊只的圈舍可以记录投喂。"))
                } else {
                    NavigationLink {
                        FeedPenSelectionView(pens: feedPens, headCountByPen: selectedDayHeadCountByPen, selection: penSelection)
                    } label: {
                        LabeledContent("圈舍", value: penEntries.isEmpty ? "请选择" : "已选 \(penEntries.count) 个")
                    }
                }
                Picker("多圈舍用量", selection: $allocationMethod) {
                    ForEach(FeedPenAllocationMethod.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("配方", selection: $recipeID) { Text("不关联配方").tag(UUID?.none); ForEach(farmRecipes, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }
                Picker("方式", selection: $mode) { ForEach(FeedMode.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) } }
                DatePicker("发生时间", selection: $occurredAt, in: ...Date.now)
                Picker("顿次", selection: $mealPeriod) {
                    ForEach(FeedMealPeriod.allCases) { period in
                        Text(LocalizedStringKey(period.rawValue)).tag(FeedMealPeriod?.some(period))
                    }
                }
                .pickerStyle(.segmented)
                Text("选择“全天”表示本条记录为当天总投料，不区分早、中、晚。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("直接投喂原料") {
                ForEach($averageLines) { $line in
                    let lineBatches = farmBatches.filter { $0.ingredientID == line.ingredientID }
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("原料", selection: $line.ingredientID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(farmIngredients, id: \.id) { ingredient in
                                Text(ingredient.name).tag(UUID?.some(ingredient.id))
                            }
                        }
                        Picker("库存批次", selection: $line.batchID) {
                            Text("请选择有库存批次").tag(UUID?.none)
                            ForEach(lineBatches, id: \.id) { batch in
                                Text(batchPickerText(batch)).tag(UUID?.some(batch.id))
                            }
                        }
                        TextField("本批投入重量 kg", text: $line.kilogramsText).keyboardType(.decimalPad)
                    }
                    .swipeActions { Button(role: .destructive) { averageLines.removeAll { $0.id == line.id } } label: { Label("删除", systemImage: "trash") } }
                }
                HStack {
                    Picker("添加原料", selection: $newIngredientID) { Text("请选择").tag(UUID?.none); ForEach(farmIngredients, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }
                    TextField("投入 kg", text: $newKilograms).keyboardType(.decimalPad).frame(width: 84)
                }
                Picker("批次", selection: $newBatchID) { Text("请选择").tag(UUID?.none); ForEach(newIngredientBatches, id: \.id) { Text($0.batchName.isEmpty ? "未命名" : $0.batchName).tag(UUID?.some($0.id)) } }
                if newIngredientID != nil && newIngredientBatches.isEmpty {
                    Text("该原料没有可用于投喂的库存批次，请先建立批次并补录库存。")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Button(averageLines.isEmpty ? LocalizedStringKey("添加到本次投料") : LocalizedStringKey("继续添加另一种原料")) { addNewLine() }
                LabeledContent("已添加原料", value: "\(averageLines.count) 种")
                LabeledContent("本次直接投料总量", value: "\(mixtureCompositionKilograms.stableText) kg")
                Text("此入口会直接扣减每种原料库存，不形成 TMR 成品批次。需要先制锅、再分顿或跨日投喂时，请使用 TMR 流程。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if allocationMethod == .averageByHeadCount {
                Section("按羊数均分设置") {
                    NavigationLink {
                        FeedCountExclusionView(
                            pens: feedPens.filter { selectedPenIDs.contains($0.id) },
                            sheepByPen: selectedDaySheepByPen,
                            recommendedSheepIDs: recommendedExcludedSheepIDs,
                            excludedSheepIDs: $excludedSheepIDs
                        )
                    } label: {
                        LabeledContent("扣除羊只计数", value: excludedSheepIDs.isEmpty ? "未扣除" : "已扣除 \(excludedSheepIDs.count)只")
                    }
                    LabeledContent("参与均分羊数", value: "\(totalCountedHeadCount)只")
                    LabeledContent("待均分投料", value: "\(mixtureCompositionKilograms.stableText) kg")
                }
                ForEach($penEntries) { $entry in
                    Section(penAverageSectionTitle(entry.penID)) {
                        LabeledContent("参与 / 当日", value: "\(countedHeadCountByPen[entry.penID] ?? 0) / \(selectedDayHeadCountByPen[entry.penID] ?? 0)只")
                        LabeledContent("分配投料", value: "\(allocatedMixtureKilograms(penID: entry.penID).stableText) kg")
                        ForEach(averageLines) { line in
                            LabeledContent(ingredientName(line.ingredientID), value: "扣 \(allocatedIngredientKilograms(line, mixtureKilograms: allocatedMixtureKilograms(penID: entry.penID)).stableText) kg")
                        }
                        TextField("该圈舍剩料（kg，可选）", text: $entry.remainingKilogramsText).keyboardType(.decimalPad)
                        TextField("该圈舍清出报废（kg，可选）", text: $entry.discardedKilogramsText).keyboardType(.decimalPad)
                    }
                }
            } else {
                ForEach($penEntries) { $entry in
                    Section(penSectionTitle(entry.penID)) {
                        TextField("该圈舍直接投料重量 kg", text: $entry.mixtureKilogramsText).keyboardType(.decimalPad)
                        ForEach(averageLines) { line in
                            LabeledContent(ingredientName(line.ingredientID), value: "扣 \(allocatedIngredientKilograms(line, mixtureKilograms: Decimal.stable(entry.mixtureKilogramsText) ?? 0).stableText) kg")
                        }
                        TextField("该圈舍剩料（kg，可选）", text: $entry.remainingKilogramsText).keyboardType(.decimalPad)
                        TextField("该圈舍清出报废（kg，可选）", text: $entry.discardedKilogramsText).keyboardType(.decimalPad)
                    }
                }
            }

            Section("合计与备注") {
                LabeledContent("已选圈舍", value: "\(penEntries.count) 个")
                LabeledContent(allocationMethod == .perPen ? "所有圈舍合计" : "整批投喂总量", value: "\(totalKilograms.stableText) kg")
                TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
            }
        }
        .navigationTitle("记录投喂")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
        .task(id: occurredAt) { await refreshFeedPenEligibility() }
        .onChange(of: recipeID) { _, _ in loadRecipe() }
        .onChange(of: occurredAt) { _, _ in
            let eligible = Set(feedPens.map(\.id))
            penEntries.removeAll { !eligible.contains($0.penID) }
            excludedSheepIDs.formIntersection(Set(selectedDaySheep.map(\.id)))
        }
        .onChange(of: newIngredientID) { _, _ in
            newBatchID = newIngredientBatches.count == 1 ? newIngredientBatches[0].id : nil
        }
    }

    @MainActor
    private func refreshFeedPenEligibility() async {
        isResolvingPenEligibility = true
        do {
            let resolved = try await FeedPenEligibilityReadActor(container: modelContext.container)
                .load(farmID: farm.id, on: occurredAt)
            try Task.checkCancellation()
            selectedDaySheepByPen = resolved.sheepByPen
            recommendedExcludedSheepIDs = resolved.recommendedExcludedSheepIDs
            let eligible = Set(resolved.sheepByPen.keys)
            penEntries.removeAll { !eligible.contains($0.penID) }
            excludedSheepIDs.formIntersection(Set(selectedDaySheep.map(\.id)))
            isResolvingPenEligibility = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "读取投喂日期的圈舍存栏失败：\(error.localizedDescription)"
            isResolvingPenEligibility = false
        }
    }

    private func batchBalanceText(_ batch: FeedIngredientBatchRecord) -> String {
        guard let value = try? FeedStockLedger.balance(for: batch, context: modelContext) else { return "待补录" }
        return "库存 \(value.stableText)kg"
    }

    private func batchPickerText(_ batch: FeedIngredientBatchRecord) -> String {
        let name = batch.batchName.isEmpty ? "未命名" : batch.batchName
        return "\(name) · \(batchBalanceText(batch))"
    }

    private func loadRecipe() {
        guard let recipeID, let recipe = farmRecipes.first(where: { $0.id == recipeID }) else { return }
        let stored = components.filter { $0.farmID == farm.id && $0.recipeID == recipe.id && $0.deletedAt == nil }
        averageLines = stored.map { FeedingLineInput(ingredientID: $0.ingredientID, batchID: $0.ingredientBatchID, kilogramsText: $0.kilogramsText) }
    }

    private func addNewLine() {
        guard !penEntries.isEmpty else { errorMessage = "请先选择投喂圈舍。"; return }
        guard let newIngredientID else { errorMessage = "请选择要加入的原料。"; return }
        guard !newIngredientBatches.isEmpty else { errorMessage = "该原料没有可用库存批次，请先建立批次并补录库存。"; return }
        guard let newBatchID else { errorMessage = "请选择原料库存批次。"; return }
        guard let kilograms = Decimal.stable(newKilograms.trimmingCharacters(in: .whitespacesAndNewlines)), kilograms > 0 else {
            errorMessage = "请输入本批原料实际投入重量。"
            return
        }
        averageLines.append(FeedingLineInput(ingredientID: newIngredientID, batchID: newBatchID, kilogramsText: newKilograms))
        errorMessage = nil
        self.newIngredientID = nil; self.newBatchID = nil; newKilograms = ""
    }

    private func updateSelectedPens(_ selection: Set<UUID>) {
        penEntries.removeAll { !selection.contains($0.penID) }
        let existing = Set(penEntries.map(\.penID))
        for pen in feedPens where selection.contains(pen.id) && !existing.contains(pen.id) {
            penEntries.append(FeedingPenInput(penID: pen.id))
        }
        let order = Dictionary(uniqueKeysWithValues: feedPens.enumerated().map { ($0.element.id, $0.offset) })
        penEntries.sort { order[$0.penID, default: .max] < order[$1.penID, default: .max] }
        excludedSheepIDs.formIntersection(Set(selectedDaySheep.map(\.id)))
    }

    private func penSectionTitle(_ penID: UUID) -> String {
        let name = feedPens.first(where: { $0.id == penID })?.name ?? "圈舍"
        return "\(name) · 当日 \(selectedDayHeadCountByPen[penID] ?? 0)只"
    }

    private func penAverageSectionTitle(_ penID: UUID) -> String {
        let name = feedPens.first(where: { $0.id == penID })?.name ?? "圈舍"
        return "\(name) · 均分预览"
    }

    private func ingredientName(_ ingredientID: UUID?) -> String {
        ingredientID.flatMap { id in farmIngredients.first(where: { $0.id == id })?.name } ?? "未选原料"
    }

    private func allocatedMixtureKilograms(penID: UUID) -> Decimal {
        guard totalCountedHeadCount > 0 else { return 0 }
        return FeedMixtureAllocator.roundedKilograms(
            mixtureCompositionKilograms * Decimal(countedHeadCountByPen[penID] ?? 0) / Decimal(totalCountedHeadCount)
        )
    }

    private func allocatedIngredientKilograms(_ line: FeedingLineInput, mixtureKilograms: Decimal) -> Decimal {
        guard mixtureCompositionKilograms > 0, let component = Decimal.stable(line.kilogramsText) else { return 0 }
        return FeedMixtureAllocator.roundedKilograms(mixtureKilograms * component / mixtureCompositionKilograms)
    }

    private func save() {
        guard !penEntries.isEmpty else { errorMessage = "请至少选择一个当日有羊的圈舍。"; return }
        let eligible = Set(feedPens.map(\.id))
        guard penEntries.allSatisfy({ eligible.contains($0.penID) }) else { errorMessage = "部分圈舍在投喂发生日期没有羊只，请重新选择。"; return }
        guard let mealPeriod else { errorMessage = "请选择顿次：早、中、晚或全天。"; return }
        guard !averageLines.isEmpty, mixtureCompositionKilograms > 0 else { errorMessage = "请先设置混合料组成和比例。"; return }
        guard averageLines.allSatisfy({ $0.ingredientID != nil && $0.batchID != nil && (Decimal.stable($0.kilogramsText) ?? 0) > 0 }) else { errorMessage = "混合料中的每种原料都必须选择库存批次并填写正数配比。"; return }

        let mixtureByPen: [UUID: Decimal]
        switch allocationMethod {
        case .perPen:
            let values = penEntries.compactMap { entry -> (UUID, Decimal)? in
                guard let value = Decimal.stable(entry.mixtureKilogramsText), value > 0 else { return nil }
                return (entry.penID, value)
            }
            guard values.count == penEntries.count else { errorMessage = "请为每个圈舍填写大于 0 的混合料重量。"; return }
            mixtureByPen = Dictionary(uniqueKeysWithValues: values)
            let distributed = values.reduce(Decimal.zero) { $0 + $1.1 }
            guard abs(NSDecimalNumber(decimal: distributed - mixtureCompositionKilograms).doubleValue) < 0.001 else {
                errorMessage = "各圈舍混合料合计必须等于本批投入总量 \(mixtureCompositionKilograms.stableText) kg，目前为 \(distributed.stableText) kg。"
                return
            }
        case .averageByHeadCount:
            guard totalCountedHeadCount > 0 else { errorMessage = "参与均分的羊只数不能为 0。"; return }
            guard penEntries.allSatisfy({ (countedHeadCountByPen[$0.penID] ?? 0) > 0 }) else { errorMessage = "每个已选圈舍至少保留 1 只羊参与均分；否则请取消该圈舍。"; return }
            mixtureByPen = FeedMixtureAllocator.mixtureByPen(
                totalKilograms: mixtureCompositionKilograms,
                weightedHeadCounts: penEntries.map { ($0.penID, countedHeadCountByPen[$0.penID] ?? 0) }
            )
        }

        let recipeHeadCount = selectedRecipe?.headCount
        let ingredientsByPen = FeedMixtureAllocator.ingredientsByPen(
            components: averageLines.compactMap { line in Decimal.stable(line.kilogramsText).map { (line.id, $0) } },
            penMixtures: penEntries.map { ($0.penID, mixtureByPen[$0.penID] ?? 0) }
        )
        let commands = penEntries.map { entry -> FarmCommand in
            let draftLines = averageLines.compactMap { line -> FeedLineDraft? in
                guard let ingredientID = line.ingredientID,
                      let batchID = line.batchID,
                      let quantity = ingredientsByPen[entry.penID]?[line.id] else { return nil }
                return FeedLineDraft(ingredientID: ingredientID, ingredientBatchID: batchID, kilogramsText: quantity.stableText)
            }
            let penSheep = selectedDaySheepByPen[entry.penID] ?? []
            let excludedSheep = allocationMethod == .averageByHeadCount
                ? penSheep.filter { excludedSheepIDs.contains($0.id) }
                : []
            let excluded = excludedSheep.map(\.earTag)
            var audit = allocationMethod == .perPen
                ? "多圈舍投喂：逐舍填写混合料重量"
                : "多圈舍投喂：按羊数均分，计数 \(countedHeadCountByPen[entry.penID] ?? 0)/\(penSheep.count)只"
            if !excluded.isEmpty { audit += "；未计入：\(excluded.joined(separator: "、"))" }
            let recordedNote = [note.trimmingCharacters(in: .whitespacesAndNewlines), audit].filter { !$0.isEmpty }.joined(separator: "\n")
            return .recordFeedV2(FeedEntryDraft(
                penID: entry.penID,
                recipeID: recipeID,
                mode: mode,
                occurredAt: occurredAt,
                mealName: mealPeriod.rawValue,
                remainingKilogramsText: entry.remainingKilogramsText.isEmpty ? nil : entry.remainingKilogramsText,
                discardedKilogramsText: entry.discardedKilogramsText.isEmpty ? nil : entry.discardedKilogramsText,
                recipeHeadCountSnapshot: recipeHeadCount,
                actualHeadCountSnapshot: allocationMethod == .averageByHeadCount ? countedHeadCountByPen[entry.penID] : selectedDayHeadCountByPen[entry.penID],
                scaleFactorText: nil,
                excludedSheepIDs: excludedSheep.map(\.id),
                lines: draftLines,
                note: recordedNote
            ))
        }
        do {
            try commandService.executeBatch(commands, in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct FeedTroughCompositionInput: Identifiable, Hashable {
    let id: UUID
    var ingredientID: UUID?
    var ingredientBatchID: UUID?
    var kilogramsText: String

    init(
        id: UUID = UUID(),
        ingredientID: UUID? = nil,
        ingredientBatchID: UUID? = nil,
        kilogramsText: String = ""
    ) {
        self.id = id
        self.ingredientID = ingredientID
        self.ingredientBatchID = ingredientBatchID
        self.kilogramsText = kilogramsText
    }
}

struct FeedTroughObservationEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var pens: [PenRecord]
    @Query private var feeds: [FeedRecord]
    @Query private var feedLines: [FeedRecordLine]
    @Query private var ingredients: [FeedIngredientRecord]
    @Query private var batches: [FeedIngredientBatchRecord]
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var penID: UUID?
    @State private var relatedFeedID: UUID?
    @State private var observedAt = Date.now
    @State private var actualRemaining = ""
    @State private var discarded = ""
    @State private var method = FeedTroughMeasurementMethod.weighed
    @State private var compositionRows: [FeedTroughCompositionInput] = []
    @State private var note = ""
    @State private var errorMessage: String?
    @State private var sheepIDsByPenAtObservation: [UUID: Set<UUID>] = [:]
    @State private var isResolvingPenEligibility = true

    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account
        self.farm = farm
        let farmID = farm.id
        _pens = Query(
            filter: #Predicate<PenRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \.name
        )
        _feeds = Query(
            filter: #Predicate<FeedRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \.occurredAt,
            order: .reverse
        )
        _feedLines = Query(filter: #Predicate<FeedRecordLine> { $0.farmID == farmID && $0.deletedAt == nil })
        _ingredients = Query(
            filter: #Predicate<FeedIngredientRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \.name
        )
        _batches = Query(
            filter: #Predicate<FeedIngredientBatchRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \.batchName
        )
    }

    private var eligiblePenIDs: Set<UUID> { Set(sheepIDsByPenAtObservation.keys) }

    private var farmPens: [PenRecord] {
        pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && eligiblePenIDs.contains($0.id) }
    }

    private var farmIngredients: [FeedIngredientRecord] {
        ingredients.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive }
    }

    private var recentFeeds: [FeedRecord] {
        let validPenIDs = eligiblePenIDs
        let selectedPenID = penID
        let observationTime = observedAt
        return feeds.filter {
            $0.occurredAt <= observationTime && validPenIDs.contains($0.penID) &&
                (selectedPenID == nil || $0.penID == selectedPenID)
        }
    }

    private var recentFeedIDs: Set<UUID> { Set(recentFeeds.map(\.id)) }

    var body: some View {
        Form {
            Section("盘槽位置") {
                Picker("圈舍", selection: $penID) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(farmPens, id: \.id) { pen in
                        Text("\(pen.name)（\(sheepIDsByPenAtObservation[pen.id, default: []].count)只）")
                            .tag(UUID?.some(pen.id))
                    }
                }
                if isResolvingPenEligibility {
                    ProgressView("正在确认该时间有羊的圈舍")
                        .font(.footnote)
                } else if farmPens.isEmpty {
                    Text("该盘槽时间没有可选的有羊圈舍。")
                        .font(.footnote).foregroundStyle(.orange)
                }
                DatePicker("盘槽时间", selection: $observedAt, in: ...Date.now)
                Picker("关联投喂（可选）", selection: $relatedFeedID) {
                    Text("不指定").tag(UUID?.none)
                    ForEach(recentFeeds, id: \.id) { feed in
                        Text(feedPickerText(feed)).tag(UUID?.some(feed.id))
                    }
                }
            }

            Section("实际盘槽") {
                TextField("盘槽时实际剩余 kg", text: $actualRemaining)
                    .keyboardType(.decimalPad)
                TextField("其中清出量 kg（可选）", text: $discarded)
                    .keyboardType(.decimalPad)
                Picker("测量方式", selection: $method) {
                    ForEach(FeedTroughMeasurementMethod.allCases, id: \.self) {
                        Text(LocalizedStringKey($0.displayName)).tag($0)
                    }
                }
                Text("实际剩余量是盘槽当时槽内总量；清出量只影响下个区间的期初，不会在本区间重复扣减。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("剩料组成（可选修正）") {
                if compositionRows.isEmpty {
                    Text("不填写时，按本批投料的均匀混合比例分摊剩料。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach($compositionRows) { $row in
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("原料", selection: $row.ingredientID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(farmIngredients, id: \.id) { ingredient in
                                Text(ingredient.name).tag(UUID?.some(ingredient.id))
                            }
                        }
                        let availableBatches = batches.filter {
                            $0.farmID == farm.id && $0.deletedAt == nil && $0.ingredientID == row.ingredientID
                        }
                        Picker("批次（可选）", selection: $row.ingredientBatchID) {
                            Text("不指定").tag(UUID?.none)
                            ForEach(availableBatches, id: \.id) {
                                Text($0.batchName.isEmpty ? "未命名批次" : $0.batchName).tag(UUID?.some($0.id))
                            }
                        }
                        TextField("该原料实际剩余 kg", text: $row.kilogramsText)
                            .keyboardType(.decimalPad)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            compositionRows.removeAll { $0.id == row.id }
                        } label: { Label("删除", systemImage: "trash") }
                    }
                }
                Button("添加剩料原料") { compositionRows.append(FeedTroughCompositionInput()) }
                if relatedFeedID != nil {
                    Button("按关联投喂比例分配剩余量", action: allocateRelatedComposition)
                }
            }

            Section("备注") {
                TextField("盘槽说明", text: $note, axis: .vertical).lineLimit(2...4)
            }
        }
        .navigationTitle("记录盘槽")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
        .task(id: observedAt) { await refreshTroughPenEligibility() }
        .onChange(of: relatedFeedID) { _, newValue in
            guard let feed = newValue.flatMap({ id in recentFeeds.first { $0.id == id } }) else {
                if newValue != nil { relatedFeedID = nil }
                return
            }
            penID = feed.penID
        }
        .onChange(of: eligiblePenIDs) { _, validIDs in
            if let penID, !validIDs.contains(penID) { self.penID = nil }
        }
        .onChange(of: recentFeedIDs) { _, validIDs in
            if let relatedFeedID, !validIDs.contains(relatedFeedID) { self.relatedFeedID = nil }
        }
    }

    @MainActor
    private func refreshTroughPenEligibility() async {
        isResolvingPenEligibility = true
        do {
            let resolved = try await FarmPenOccupancyReadActor(container: modelContext.container)
                .sheepIDsByPen(farmID: farm.id, at: observedAt)
            try Task.checkCancellation()
            sheepIDsByPenAtObservation = resolved
            isResolvingPenEligibility = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "读取该时间的圈舍存栏失败：\(error.localizedDescription)"
            isResolvingPenEligibility = false
        }
    }

    private func feedPickerText(_ feed: FeedRecord) -> String {
        let penName = farmPens.first(where: { $0.id == feed.penID })?.name ?? "圈舍"
        return "\(feed.occurredAt.formatted(date: .abbreviated, time: .shortened)) · \(penName) · \(feed.mode.displayName)"
    }

    private var legacyFeederName: String {
        guard let relatedFeedID,
              let feed = recentFeeds.first(where: { $0.id == relatedFeedID }) else { return "" }
        return feed.feederName
    }

    private func allocateRelatedComposition() {
        guard let feedID = relatedFeedID,
              let remaining = Decimal.stable(actualRemaining), remaining >= 0 else {
            errorMessage = "请先填写实际剩余量。"
            return
        }
        let lines = feedLines.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.feedRecordID == feedID }
        let total = lines.reduce(Decimal.zero) { $0 + $1.kilograms }
        guard total > 0 else { errorMessage = "关联投喂没有可用原料明细。"; return }
        var allocated = Decimal.zero
        compositionRows = lines.enumerated().map { index, line in
            let quantity: Decimal
            if index == lines.indices.last {
                quantity = remaining - allocated
            } else {
                var exact = remaining * line.kilograms / total
                var rounded = Decimal.zero
                NSDecimalRound(&rounded, &exact, 3, .bankers)
                quantity = rounded
                allocated += rounded
            }
            return FeedTroughCompositionInput(
                ingredientID: line.ingredientID,
                ingredientBatchID: line.ingredientBatchID,
                kilogramsText: quantity.stableText
            )
        }
        errorMessage = nil
    }

    private func save() {
        guard let penID else { errorMessage = "请选择圈舍。"; return }
        let components: [FeedTroughCompositionComponent]
        if compositionRows.isEmpty {
            components = []
        } else {
            components = compositionRows.compactMap { row in
                guard let ingredientID = row.ingredientID,
                      let ingredient = farmIngredients.first(where: { $0.id == ingredientID }),
                      let quantity = Decimal.stable(row.kilogramsText), quantity >= 0 else { return nil }
                let snapshotLine = relatedFeedID.flatMap { feedID in
                    feedLines.first {
                        $0.feedRecordID == feedID &&
                            ($0.ingredientBatchID == row.ingredientBatchID ||
                                (row.ingredientBatchID == nil && $0.ingredientID == ingredientID))
                    }
                }
                return FeedTroughCompositionComponent(
                    ingredientID: ingredientID,
                    ingredientBatchID: row.ingredientBatchID,
                    ingredientNameSnapshot: snapshotLine?.ingredientNameSnapshot ?? ingredient.name,
                    kilogramsText: quantity.stableText,
                    nutrientSnapshotJSON: snapshotLine?.nutrientSnapshotJSON ?? ingredient.nutrientSnapshotJSON,
                    dryMatterTextSnapshot: snapshotLine?.dryMatterTextSnapshot ?? ingredient.dryMatterText
                )
            }
            guard components.count == compositionRows.count else {
                errorMessage = "剩料组成的每一行都要选择原料并填写非负重量。"
                return
            }
        }
        let compositionJSON = components.isEmpty ? nil : FeedTroughCompositionCodec.encode(components)
        do {
            try commandService.execute(
                .recordFeedTroughObservation(FeedTroughObservationDraft(
                    penID: penID,
                    relatedFeedRecordID: relatedFeedID,
                    feederName: legacyFeederName,
                    observedAt: observedAt,
                    actualRemainingKilogramsText: actualRemaining,
                    discardedKilogramsText: discarded.isEmpty ? nil : discarded,
                    measurementMethod: method,
                    compositionSnapshotJSON: compositionJSON,
                    note: note
                )),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct FeedHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var snapshot = FeedHistoryScreenSnapshot.empty
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var sourceRevision = 0

    private var loadTaskID: String {
        "\(farm.id.uuidString.lowercased()):\(sourceRevision)"
    }

    var body: some View {
        List {
            Section("投喂") {
                ForEach(snapshot.feeds) { feed in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(feed.penName).font(.headline); Spacer(); Text(LocalizedStringKey(feed.modeName)).font(.caption).foregroundStyle(.secondary) }
                        Text("\(feed.lineCount) 种原料 · \(feed.kilogramsText) kg")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if !feed.feederName.isEmpty { Text("旧位置备注：\(feed.feederName)").font(.caption).foregroundStyle(.secondary) }
                        if let factor = feed.scaleFactorText { Text("执行缩放系数：\(factor)").font(.caption).foregroundStyle(.orange) }
                        if feed.excludedSheepCount > 0 { Text("排除 \(feed.excludedSheepCount) 只羊").font(.caption).foregroundStyle(.orange) }
                        Text(feed.occurredAt, format: .dateTime.year().month().day().hour().minute()).font(.footnote).foregroundStyle(.tertiary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { delete(feed) } label: { Label("删除并冲回库存", systemImage: "trash") }
                    }
                }
            }
            Section("盘槽") {
                ForEach(snapshot.troughs) { trough in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(trough.penName).font(.headline)
                        if !trough.feederName.isEmpty { Text("旧位置备注：\(trough.feederName)").font(.caption).foregroundStyle(.secondary) }
                        Text("剩余 \(trough.actualRemainingKilogramsText) kg · 清出 \(trough.discardedKilogramsText) kg · \(trough.measurementMethodName)")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(trough.observedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.footnote).foregroundStyle(.tertiary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { delete(trough) } label: { Label("删除盘槽", systemImage: "trash") }
                    }
                }
            }
        }
        .overlay {
            if isLoading {
                ProgressView("正在整理投喂历史")
            } else if let loadError {
                ContentUnavailableView("读取失败", systemImage: "exclamationmark.triangle", description: Text(LocalizedStringKey(loadError)))
            } else if snapshot.feeds.isEmpty && snapshot.troughs.isEmpty {
                ContentUnavailableView("还没有投喂或盘槽记录", systemImage: "clock.arrow.circlepath")
            }
        }
        .navigationTitle("投喂历史")
        .task(id: loadTaskID) { await loadHistory() }
        .onReceive(NotificationCenter.default.publisher(for: CloudRuntimeNotification.syncWake)) { notification in
            guard CloudRuntimeNotification.farmID(from: notification) == farm.id else { return }
            sourceRevision &+= 1
        }
    }

    @MainActor
    private func loadHistory() async {
        isLoading = true
        loadError = nil
        do {
            snapshot = try await FeedHistorySnapshotActor(container: modelContext.container)
                .load(farmID: farm.id)
            try Task.checkCancellation()
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    private func delete(_ feed: FeedHistoryFeedSnapshot) {
        do {
            try commandService.execute(.tombstoneEntity(entityType: .feed, entityID: feed.id, reason: "删除投喂并冲回库存"), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            sourceRevision &+= 1
        } catch { loadError = error.localizedDescription }
    }

    private func delete(_ trough: FeedHistoryTroughSnapshot) {
        do {
            try commandService.execute(
                .tombstoneEntity(entityType: .feedTroughObservation, entityID: trough.id, reason: "删除盘槽记录"),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: modelContext
            )
            sourceRevision &+= 1
        } catch { loadError = error.localizedDescription }
    }
}

private enum FeedAnalysisRangePreset: String, CaseIterable, Identifiable {
    case sevenDays = "近7日"
    case thirtyDays = "近30日"
    case custom = "自定义"

    var id: Self { self }
}

private struct FeedAnalysisPenFilterView: View {
    @Environment(\.dismiss) private var dismiss
    let pens: [FeedAnalysisPenSnapshot]
    @Binding var selection: Set<UUID>

    var body: some View {
        List(selection: $selection) {
            ForEach(pens, id: \.id) { pen in
                Text(pen.name).tag(pen.id)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("筛选圈舍")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("全部圈舍") { selection.removeAll() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }.fontWeight(.semibold)
            }
        }
    }
}

struct FarmAnalyticsView: View {
    @Environment(\.modelContext) private var modelContext
    let farm: FarmRecord
    @State private var preset = FeedAnalysisRangePreset.sevenDays
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: .now)) ?? .now
    @State private var customEnd = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now)) ?? .now
    @State private var selectedPenIDs = Set<UUID>()
    @State private var screenSnapshot: FeedIntakeAnalysisScreenSnapshot?
    @State private var isCalculating = false
    @State private var errorMessage: String?

    private var range: (start: Date, end: Date) {
        let today = Calendar.current.startOfDay(for: .now)
        switch preset {
        case .sevenDays:
            return (Calendar.current.date(byAdding: .day, value: -7, to: today) ?? today, today)
        case .thirtyDays:
            return (Calendar.current.date(byAdding: .day, value: -30, to: today) ?? today, today)
        case .custom:
            let start = Calendar.current.startOfDay(for: min(customStart, customEnd))
            let inclusiveEnd = Calendar.current.startOfDay(for: max(customStart, customEnd))
            let end = min(today, Calendar.current.date(byAdding: .day, value: 1, to: inclusiveEnd) ?? today)
            return (min(start, end), end)
        }
    }

    private var farmPens: [FeedAnalysisPenSnapshot] {
        screenSnapshot?.eligiblePens ?? []
    }

    private var loadKey: String {
        let selection = selectedPenIDs.map(\.uuidString).sorted().joined(separator: ",")
        return "\(farm.id.uuidString)|\(range.start.timeIntervalSinceReferenceDate)|\(range.end.timeIntervalSinceReferenceDate)|\(selection)"
    }

    var body: some View {
        List {
            Section("分析范围") {
                Picker("日期", selection: $preset) {
                    ForEach(FeedAnalysisRangePreset.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                if preset == .custom {
                    DatePicker("开始日期", selection: $customStart, displayedComponents: .date)
                    DatePicker("结束日期", selection: $customEnd, in: ...Calendar.current.startOfDay(for: .now), displayedComponents: .date)
                }
                NavigationLink {
                    FeedAnalysisPenFilterView(pens: farmPens, selection: $selectedPenIDs)
                } label: {
                    LabeledContent("圈舍") {
                        if selectedPenIDs.isEmpty {
                            Text("全部")
                        } else {
                            Text("已选 \(selectedPenIDs.count) 个")
                        }
                    }
                }
                Text("正式日均只计算截至昨天的完整自然日；晚补录转群、离场、投喂或盘槽后会按事实时间重新计算。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if let result = screenSnapshot?.result {
                Section("全场概览") {
                    LabeledContent("分析期间", value: rangeText(result.start, result.end))
                    LabeledContent("真实投喂羊天", value: FeedAnalysisNumberFormatter.total(result.overview.feedingSheepDays))
                    LabeledContent("有效圈舍") {
                        Text("\(result.overview.effectivePenCount)个")
                    }
                    LabeledContent("记录完整率", value: FeedAnalysisNumberFormatter.percent(result.overview.recordCompleteness))
                    LabeledContent("实测 / 估算", value: "\(FeedAnalysisNumberFormatter.percent(result.overview.measuredRatio)) / \(FeedAnalysisNumberFormatter.percent(result.overview.estimatedRatio))")
                    if result.overview.conflictCount > 0 {
                        Label("存在 \(result.overview.conflictCount) 个数据冲突，相关区间未参与营养预测", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section("逐舍采食与营养") {
                    if result.pens.isEmpty {
                        ContentUnavailableView("分析期间没有可计算采食", systemImage: "chart.bar.xaxis", description: Text("自由采食需要两个盘槽边界；旧记录会明确标为估算。"))
                    } else {
                        ForEach(result.pens) { pen in
                            NavigationLink { FeedIntakePenDetailView(result: pen) } label: {
                                FeedIntakePenSummaryRow(result: pen)
                            }
                        }
                    }
                }
            } else if let errorMessage {
                Section {
                    ContentUnavailableView(
                        "无法读取采食分析",
                        systemImage: "exclamationmark.triangle",
                        description: Text(LocalizedStringKey(errorMessage))
                    )
                    Button("重新计算") {
                        Task { await loadAnalysis() }
                    }
                }
            } else {
                Section {
                    ProgressView(isCalculating ? "正在重算羊天、采食和营养" : "正在准备分析")
                }
            }

            Section("今日（进行中）") {
                LabeledContent("已记录投喂") {
                    Text("\(screenSnapshot?.todayFeedCount ?? 0)次")
                }
                LabeledContent("已投料") {
                    Text("\(FeedAnalysisNumberFormatter.total(screenSnapshot?.todayKilograms)) kg")
                }
                Text("今天尚未结束，不混入正式日均；盘槽闭合后会在下一完整日分析中体现。")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .navigationTitle("采食营养分析")
        .task(id: loadKey) {
            await loadAnalysis()
        }
        .refreshable {
            await loadAnalysis()
        }
    }

    @MainActor
    private func loadAnalysis() async {
        isCalculating = true
        errorMessage = nil
        do {
            let loaded = try await FeedIntakeAnalysisSnapshotActor(container: modelContext.container).load(
                farmID: farm.id,
                start: range.start,
                end: range.end,
                selectedPenIDs: selectedPenIDs
            )
            try Task.checkCancellation()
            screenSnapshot = loaded
            selectedPenIDs.formIntersection(Set(loaded.eligiblePens.map(\.id)))
            isCalculating = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            isCalculating = false
        }
    }

    private func rangeText(_ start: Date, _ end: Date) -> String {
        let inclusiveEnd = end.addingTimeInterval(-0.001)
        return "\(start.formatted(date: .numeric, time: .omitted))–\(inclusiveEnd.formatted(date: .numeric, time: .omitted))"
    }
}

private struct FeedIntakePenSummaryRow: View {
    let result: FeedIntakePenResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(result.name).font(.headline)
                Spacer()
                Text(LocalizedStringKey(statusText)).font(.caption).foregroundStyle(statusColor)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    metric("鲜重", Text("\(FeedAnalysisNumberFormatter.total(result.freshKilograms)) kg"))
                    metric("DMI", Text("\(FeedAnalysisNumberFormatter.perHead(result.nutrition.dryMatterKilogramsPerSheepDay)) kg/羊天"))
                }
                GridRow {
                    metric("ME", Text("\(FeedAnalysisNumberFormatter.total(result.nutrition.meMJPerSheepDay)) MJ/羊天"))
                    metric("支持日增重", growthTextView)
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func metric(_ title: String, _ value: Text) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
            value.font(.subheadline.monospacedDigit())
        }
    }

    private var growthTextView: Text {
        if let value = result.growth.calibratedExpectedADGKg ?? result.growth.nutritionPotentialADGKg {
            return Text("\(FeedAnalysisNumberFormatter.integer(value * 1_000)) g/天")
        }
        if result.growth.stage == .breedingEwe || result.growth.stage == .breedingRam { return Text("维持差额") }
        return Text("数据不足")
    }

    private var statusText: String {
        if !result.conflicts.isEmpty { return "数据冲突" }
        if result.incompleteIntervalCount > 0 { return "部分未闭合" }
        if result.evidence.contains(.measured) && result.evidence.contains(.estimated) { return "实测+估算" }
        if result.evidence.contains(.estimated) { return "估算" }
        if result.evidence.contains(.historicalHeadCount) { return "历史人数估算" }
        return "实测"
    }

    private var statusColor: Color {
        !result.conflicts.isEmpty ? .red : (result.evidence.contains(.estimated) || result.incompleteIntervalCount > 0 ? .orange : .secondary)
    }
}

private struct FeedIntakePenDetailView: View {
    let result: FeedIntakePenResult

    var body: some View {
        List {
            Section("采食概览") {
                LabeledContent("全舍鲜重", value: "\(FeedAnalysisNumberFormatter.total(result.freshKilograms)) kg")
                LabeledContent("真实投喂羊天", value: FeedAnalysisNumberFormatter.total(result.sheepDays))
                LabeledContent("每只每天鲜重", value: "\(FeedAnalysisNumberFormatter.perHead(result.nutrition.freshKilogramsPerSheepDay)) kg")
                LabeledContent("每只每天DMI", value: "\(FeedAnalysisNumberFormatter.perHead(result.nutrition.dryMatterKilogramsPerSheepDay)) kg")
            }

            Section("原料组成") {
                ForEach(result.ingredients) { ingredient in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ingredient.name).font(.headline)
                        Text("全舍 \(FeedAnalysisNumberFormatter.total(ingredient.freshKilograms)) kg · \(FeedAnalysisNumberFormatter.perHead(ingredient.freshKilogramsPerSheepDay)) kg/羊天")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }

            Section("营养供应（每只每天）") {
                LabeledContent("ME", value: "\(FeedAnalysisNumberFormatter.total(result.nutrition.meMJPerSheepDay)) MJ")
                LabeledContent("CP", value: "\(FeedAnalysisNumberFormatter.integer(result.nutrition.crudeProteinGramsPerSheepDay)) g")
                LabeledContent("MP", value: "\(FeedAnalysisNumberFormatter.integer(result.nutrition.metabolizableProteinGramsPerSheepDay)) g")
                LabeledContent("NDF", value: "\(FeedAnalysisNumberFormatter.integer(result.nutrition.ndfGramsPerSheepDay)) g")
                LabeledContent("ADF", value: "\(FeedAnalysisNumberFormatter.integer(result.nutrition.adfGramsPerSheepDay)) g")
                if result.nutrition.mpEstimated {
                    Text("MP：仅有CP时采用Plus兼容估算模型。")
                        .font(.footnote).foregroundStyle(.orange)
                } else if let reason = result.nutrition.mpBlockedReason {
                    Text("MP未计算：\(reason)").font(.footnote).foregroundStyle(.orange)
                }
            }

            Section("营养浓度与覆盖") {
                ForEach(FeedNutrientKey.allCases, id: \.self) { key in
                    if shouldShowNutrient(key) {
                        nutrientRow(key)
                    }
                }
                ForEach(result.nutrition.summary.extraCoverage.keys.sorted(), id: \.self) { key in
                    if let value = result.nutrition.summary.nutrients.extra?[key] {
                        LabeledContent(key, value: FeedAnalysisNumberFormatter.perHead(value))
                    } else if let coverage = result.nutrition.summary.extraCoverage[key] {
                        missingCoverageRow(name: key, coverage: coverage)
                    }
                }
            }

            Section("生长支持") {
                LabeledContent("阶段") {
                    if let stage = result.growth.stage {
                        Text(LocalizedStringKey(stage.rawValue))
                    } else {
                        Text("数据不足")
                    }
                }
                LabeledContent("阶段占比", value: FeedAnalysisNumberFormatter.percent(result.growth.dominantStageRatio))
                LabeledContent("平均体重", value: "\(FeedAnalysisNumberFormatter.total(result.growth.averageWeightKilograms)) kg")
                LabeledContent("体重覆盖", value: "\(result.growth.weightSampleCount)/\(result.growth.requiredWeightSampleCount) · \(FeedAnalysisNumberFormatter.percent(result.growth.weightCoverage))")
                if let maintenanceME = result.growth.maintenanceMEPerDay {
                    LabeledContent("维持ME需要", value: "\(FeedAnalysisNumberFormatter.total(maintenanceME)) MJ/天")
                    LabeledContent("维持ME差额", value: "\(FeedAnalysisNumberFormatter.total(result.growth.maintenanceMEGap)) MJ/天")
                    LabeledContent("维持MP差额", value: "\(FeedAnalysisNumberFormatter.integer(result.growth.maintenanceMPGapGrams)) g/天")
                }
                LabeledContent("营养支持日增重", value: adgText(result.growth.nutritionPotentialADGKg))
                LabeledContent("本场实测日增重", value: adgText(result.growth.observedADGKg))
                LabeledContent("校准预期日增重", value: adgText(result.growth.calibratedExpectedADGKg))
                if let limiting = result.growth.limitingFactor { LabeledContent("限制因素", value: limiting) }
                if let blocked = result.growth.blockedReason {
                    Text("停止预测：\(blocked)").font(.footnote).foregroundStyle(.orange)
                }
                Text(LocalizedStringKey(result.growth.modelDescription)).font(.footnote).foregroundStyle(.secondary)
            }

            Section("每日趋势") {
                ForEach(result.dailyTrend) { day in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(day.date, format: .dateTime.year().month().day()).font(.headline)
                        Text("鲜重 \(FeedAnalysisNumberFormatter.total(day.freshKilograms)) kg · 羊天 \(FeedAnalysisNumberFormatter.total(day.sheepDays)) · DMI \(FeedAnalysisNumberFormatter.perHead(day.dmiKilogramsPerSheepDay)) kg/羊天 · ME \(FeedAnalysisNumberFormatter.total(day.meMJPerSheepDay)) MJ/羊天")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Section("数据依据") {
                Text("完整区间 \(result.completeIntervalCount) 个；未闭合或冲突区间 \(result.incompleteIntervalCount) 个。")
                ForEach(result.evidence.map(\.rawValue).sorted(), id: \.self) { value in
                    Label { Text(LocalizedStringKey(value)) } icon: { Image(systemName: "checkmark.circle") }
                }
                ForEach(result.conflicts, id: \.self) { conflict in
                    Label { Text(verbatim: conflict) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(result.name)
    }

    private func shouldShowNutrient(_ key: FeedNutrientKey) -> Bool {
        result.nutrition.summary.nutrients.value(for: key) != nil ||
            result.nutrition.summary.coverage[key].map { !$0.isComplete } == true
    }

    @ViewBuilder
    private func nutrientRow(_ key: FeedNutrientKey) -> some View {
        if let value = result.nutrition.summary.nutrients.value(for: key) {
            let converted = key.isEnergy ? value * FeedNutrients.megajoulesPerMegacalorie : value
            let unit = key.isEnergy ? "MJ/kg DM" : "%"
            let coverage = result.nutrition.summary.coverage[key]
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent(key.displayName, value: "\(FeedAnalysisNumberFormatter.perHead(converted)) \(unit)")
                if coverage?.inferred == true {
                    Text("由TDN/DE/ME推算").font(.caption).foregroundStyle(.orange)
                }
            }
        } else if let coverage = result.nutrition.summary.coverage[key] {
            missingCoverageRow(name: key.displayName, coverage: coverage)
        }
    }

    @ViewBuilder
    private func missingCoverageRow(name: String, coverage: FeedNutrientCoverage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(name, value: "覆盖 \(FeedAnalysisNumberFormatter.percent(coverage.coverage))")
            if !coverage.missingIngredientNames.isEmpty {
                Text("缺失：\(coverage.missingIngredientNames.joined(separator: "、"))")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func adgText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(FeedAnalysisNumberFormatter.integer(value * 1_000)) g/天"
    }
}
