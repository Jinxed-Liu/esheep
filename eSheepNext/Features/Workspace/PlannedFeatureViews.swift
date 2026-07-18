import SwiftData
import SwiftUI

struct FeedingStartView: View {
    @Environment(AppSession.self) private var session
    @Query(sort: \FeedRecord.occurredAt, order: .reverse) private var feedRecords: [FeedRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @State private var isFeedEntryPresented = false

    private var todayCount: Int {
        let start = Calendar.current.startOfDay(for: .now)
        return feedRecords.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.occurredAt >= start }.count
    }

    var body: some View {
        List {
            Section {
                LabeledContent("今日投喂", value: "\(todayCount) 条")
                Text("投喂记录按圈舍、发生时间和原料明细保存。自由采食分析只使用具有后续边界的真实记录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("日常投喂") {
                NavigationLink { FeedEntryView(account: account, farm: farm) } label: { Label("记录投喂", systemImage: "plus.circle") }
                NavigationLink { FeedHistoryView(farm: farm) } label: { Label("投喂历史", systemImage: "clock.arrow.circlepath") }
                NavigationLink { FarmAnalyticsView(farm: farm) } label: { Label("采食分析", systemImage: "chart.bar") }
            }
            Section("原料与配方") {
                NavigationLink { IngredientLibraryView(account: account, farm: farm) } label: { Label("原料库", systemImage: "shippingbox") }
                NavigationLink { RecipeLibraryView(account: account, farm: farm) } label: { Label("配方管理", systemImage: "list.bullet.rectangle") }
            }
        }
        .navigationTitle("投喂")
        .sheet(isPresented: $isFeedEntryPresented) {
            NavigationStack {
                FeedEntryView(account: account, farm: farm)
            }
        }
        .onAppear(perform: presentIntentEntryIfNeeded)
        .onChange(of: session.pendingRecordEntry) { _, _ in
            presentIntentEntryIfNeeded()
        }
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

    var body: some View {
        List {
            ForEach(ingredients.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive }, id: \.id) { ingredient in
                VStack(alignment: .leading, spacing: 3) {
                    Text(ingredient.name).font(.headline)
                    Text(ingredient.dryMatterText.map { "单位：\(ingredient.unit) · 干物质：\($0)%" } ?? "单位：\(ingredient.unit)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if ingredients.allSatisfy({ $0.farmID != farm.id || $0.deletedAt != nil || !$0.isActive }) {
                ContentUnavailableView("还没有原料", systemImage: "shippingbox", description: Text("先建立原料库，再记录投喂或组成配方。"))
            }
        }
        .navigationTitle("原料库")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { isAdding = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $isAdding) { NavigationStack { AddIngredientView(account: account, farm: farm) } }
    }
}

private struct AddIngredientView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var name = ""
    @State private var unit = "千克"
    @State private var dryMatter = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("原料名称", text: $name)
            TextField("单位", text: $unit)
            TextField("干物质（百分比，可选）", text: $dryMatter).keyboardType(.decimalPad)
        }
        .navigationTitle("新增原料")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        do {
            try commandService.execute(.addIngredient(name: name, unit: unit, dryMatterText: dryMatter), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct RecipeLibraryView: View {
    @Query(sort: \FeedRecipeRecord.name) private var recipes: [FeedRecipeRecord]
    @Query private var components: [FeedRecipeComponentRecord]
    @Query(sort: \FeedIngredientRecord.name) private var ingredients: [FeedIngredientRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @State private var isAdding = false

    var body: some View {
        List {
            ForEach(recipes.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive }, id: \.id) { recipe in
                NavigationLink { RecipeDetailView(account: account, farm: farm, recipe: recipe) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recipe.name).font(.headline)
                        let count = components.filter { $0.recipeID == recipe.id && $0.farmID == farm.id }.count
                        Text("\(count) 种原料").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if recipes.allSatisfy({ $0.farmID != farm.id || $0.deletedAt != nil || !$0.isActive }) {
                ContentUnavailableView("还没有配方", systemImage: "list.bullet.rectangle", description: Text("配方由原料及其用量组成，记录后会保留历史快照。"))
            }
        }
        .navigationTitle("配方")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { isAdding = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $isAdding) { NavigationStack { AddRecipeView(account: account, farm: farm) } }
    }
}

private struct AddRecipeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var name = ""
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form { TextField("配方名称", text: $name); TextField("说明", text: $note, axis: .vertical).lineLimit(2...4) }
            .navigationTitle("新建配方")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .recordErrorAlert($errorMessage)
    }

    private func save() {
        do {
            try commandService.execute(.createRecipe(name: name, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct RecipeDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var components: [FeedRecipeComponentRecord]
    @Query(sort: \FeedIngredientRecord.name) private var ingredients: [FeedIngredientRecord]
    let account: AccountProfile
    let farm: FarmRecord
    let recipe: FeedRecipeRecord
    private let commandService = FarmCommandService()
    @State private var ingredientID: UUID?
    @State private var kilograms = ""
    @State private var errorMessage: String?

    private var recipeComponents: [FeedRecipeComponentRecord] { components.filter { $0.farmID == farm.id && $0.recipeID == recipe.id } }
    private var farmIngredients: [FeedIngredientRecord] { ingredients.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var names: [UUID: String] { Dictionary(uniqueKeysWithValues: farmIngredients.map { ($0.id, $0.name) }) }

    var body: some View {
        List {
            Section("组成") {
                ForEach(recipeComponents, id: \.id) { component in
                    LabeledContent(names[component.ingredientID] ?? "已停用原料", value: "\(component.kilogramsText) 千克")
                }
            }
            Section("添加原料") {
                Picker("原料", selection: $ingredientID) { Text("请选择").tag(UUID?.none); ForEach(farmIngredients, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }
                TextField("用量（千克）", text: $kilograms).keyboardType(.decimalPad)
                Button("添加到配方", action: addComponent).disabled(ingredientID == nil || kilograms.isEmpty)
            }
        }
        .navigationTitle(recipe.name)
        .recordErrorAlert($errorMessage)
    }

    private func addComponent() {
        guard let ingredientID else { return }
        do {
            try commandService.execute(.addRecipeComponent(recipeID: recipe.id, ingredientID: ingredientID, kilogramsText: kilograms), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            self.ingredientID = nil
            kilograms = ""
        } catch { errorMessage = error.localizedDescription }
    }
}

struct FeedEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query(sort: \FeedIngredientRecord.name) private var ingredients: [FeedIngredientRecord]
    @Query(sort: \FeedIngredientBatchRecord.batchName) private var ingredientBatches: [FeedIngredientBatchRecord]
    @Query(sort: \FeedRecipeRecord.name) private var recipes: [FeedRecipeRecord]
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var penID: UUID?
    @State private var recipeID: UUID?
    @State private var mode = FeedMode.limited
    @State private var occurredAt = Date.now
    @State private var ingredientID: UUID?
    @State private var ingredientBatchID: UUID?
    @State private var kilograms = ""
    @State private var lines: [FeedLineDraft] = []
    @State private var note = ""
    @State private var errorMessage: String?

    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var farmIngredients: [FeedIngredientRecord] { ingredients.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var selectableBatches: [FeedIngredientBatchRecord] {
        ingredientBatches.filter {
            $0.farmID == farm.id && $0.isActive && $0.ingredientID == ingredientID
        }
    }
    private var farmRecipes: [FeedRecipeRecord] { recipes.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var names: [UUID: String] { Dictionary(uniqueKeysWithValues: farmIngredients.map { ($0.id, $0.name) }) }
    private var batchNames: [UUID: String] { Dictionary(uniqueKeysWithValues: ingredientBatches.filter { $0.farmID == farm.id }.map { ($0.id, $0.batchName) }) }

    var body: some View {
        Form {
            Section("投喂对象") {
                Picker("圈舍", selection: $penID) { Text("请选择").tag(UUID?.none); ForEach(farmPens, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }
                Picker("配方（可选）", selection: $recipeID) { Text("不关联配方").tag(UUID?.none); ForEach(farmRecipes, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }
                Picker("方式", selection: $mode) { ForEach(FeedMode.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                DatePicker("发生时间", selection: $occurredAt)
            }
            Section("原料明细") {
                ForEach(lines, id: \.id) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(names[line.ingredientID] ?? "已停用原料"); Spacer(); Text("\(line.kilogramsText) 千克").foregroundStyle(.secondary) }
                        if let batchID = line.ingredientBatchID, let batchName = batchNames[batchID], !batchName.isEmpty {
                            Text("批次：\(batchName)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { lines.remove(atOffsets: $0) }
                Picker("原料", selection: $ingredientID) { Text("请选择").tag(UUID?.none); ForEach(farmIngredients, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }
                Picker("原料批次（可选）", selection: $ingredientBatchID) {
                    Text("未指定批次").tag(UUID?.none)
                    ForEach(selectableBatches, id: \.id) { batch in
                        Text(batch.batchName.isEmpty ? "未命名批次" : batch.batchName).tag(UUID?.some(batch.id))
                    }
                }
                TextField("数量（千克）", text: $kilograms).keyboardType(.decimalPad)
                Button("添加原料") { addLine() }.disabled(ingredientID == nil || kilograms.isEmpty)
            }
            Section("备注") { TextField("可选", text: $note, axis: .vertical).lineLimit(2...4) }
        }
        .navigationTitle("记录投喂")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
        }
        .recordErrorAlert($errorMessage)
        .onChange(of: ingredientID) { _, _ in ingredientBatchID = nil }
    }

    private func addLine() {
        guard let ingredientID else { return }
        lines.append(FeedLineDraft(ingredientID: ingredientID, ingredientBatchID: ingredientBatchID, kilogramsText: kilograms))
        self.ingredientID = nil
        ingredientBatchID = nil
        kilograms = ""
    }

    private func save() {
        guard let penID else { errorMessage = "请选择圈舍。"; return }
        do {
            try commandService.execute(.recordFeed(penID: penID, recipeID: recipeID, mode: mode, occurredAt: occurredAt, lines: lines, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct FeedHistoryView: View {
    @Query(sort: \FeedRecord.occurredAt, order: .reverse) private var feeds: [FeedRecord]
    @Query private var lines: [FeedRecordLine]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    let farm: FarmRecord

    private var names: [UUID: String] { Dictionary(uniqueKeysWithValues: pens.filter { $0.farmID == farm.id }.map { ($0.id, $0.name) }) }

    var body: some View {
        List {
            ForEach(feeds.filter { $0.farmID == farm.id && $0.deletedAt == nil }, id: \.id) { feed in
                VStack(alignment: .leading, spacing: 4) {
                    Text(names[feed.penID] ?? "已删除圈舍").font(.headline)
                    Text("\(feed.mode.displayName) · \(lines.filter { $0.feedRecordID == feed.id && $0.farmID == farm.id }.count) 种原料")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(feed.occurredAt, format: .dateTime.year().month().day().hour().minute()).font(.footnote).foregroundStyle(.tertiary)
                }
            }
        }
        .navigationTitle("投喂历史")
    }
}

struct FarmAnalyticsView: View {
    @Query private var sheep: [SheepRecord]
    @Query private var transfers: [TransferRecord]
    @Query private var feeds: [FeedRecord]
    @Query private var lines: [FeedRecordLine]
    let farm: FarmRecord
    @State private var results: [IngredientIntakeResult]?
    @State private var isCalculating = false

    private var sourceRevision: [Int] { [sheep.count, transfers.count, feeds.count, lines.count] }

    private func makeInput() -> (feeds: [FeedSnapshot], sheep: [SheepPresenceSnapshot], transfers: [TransferSnapshot]) {
        let snapshots = sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil }.map { SheepPresenceSnapshot(sheepID: $0.id, initialPenID: $0.initialPenID, enteredAt: $0.enteredAt, removedAt: $0.removedAt) }
        let transferSnapshots = transfers.filter { $0.farmID == farm.id && $0.deletedAt == nil }.map { TransferSnapshot(sheepID: $0.sheepID, toPenID: $0.toPenID, occurredAt: $0.occurredAt, recordedAt: $0.recordedAt, stableID: $0.id) }
        let feedByID = Dictionary(uniqueKeysWithValues: feeds.filter { $0.farmID == farm.id && $0.deletedAt == nil }.map { ($0.id, $0) })
        let feedSnapshots = lines.filter { $0.farmID == farm.id }.compactMap { line -> FeedSnapshot? in
            guard let feed = feedByID[line.feedRecordID] else { return nil }
            return FeedSnapshot(feedID: feed.id, penID: feed.penID, ingredientID: line.ingredientID, ingredientName: line.ingredientNameSnapshot, kilograms: line.kilograms, mode: feed.mode, occurredAt: feed.occurredAt)
        }
        return (feedSnapshots, snapshots, transferSnapshots)
    }

    var body: some View {
        List {
            Section {
                Text("自由采食按每种原料计算，使用历史圈舍和真实羊天。最后一条未闭合的添加记录不会被推算为消耗。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("自由采食结果") {
                if let results {
                    if results.isEmpty { Text("需要至少两天的同一圈舍、同一原料自由采食记录，才能形成有效区间。").foregroundStyle(.secondary) }
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.ingredientName).font(.headline)
                            if let perDay = result.kilogramsPerSheepDay {
                                Text("\(perDay.stableText) 千克／羊天 · \(result.sheepDays.stableText) 羊天")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                Text("羊天缺失，未计算单位采食量").font(.subheadline).foregroundStyle(.secondary)
                            }
                            if result.hasMissingFinalBoundary { Text("最新一次添加尚无后续边界，未纳入消耗推算。").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                } else {
                    ProgressView(isCalculating ? "正在计算真实羊天" : "正在准备采食分析")
                }
            }
        }
        .navigationTitle("采食分析")
        .onAppear(perform: refresh)
        .onChange(of: sourceRevision) { _, _ in refresh() }
    }

    private func refresh() {
        let input = makeInput()
        isCalculating = true
        Task {
            let calculation = await Task.detached(priority: .userInitiated) {
                FarmAnalytics.freeChoiceIntake(from: input.feeds, sheep: input.sheep, transfers: input.transfers)
            }.value
            results = calculation
            isCalculating = false
        }
    }
}
