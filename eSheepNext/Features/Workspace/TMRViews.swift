import SwiftData
import SwiftUI

private func tmrDecimal(_ text: String) -> Decimal? {
    Decimal.stable(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func tmrPercentFraction(_ text: String) -> String {
    ((tmrDecimal(text) ?? 0) / 100).stableText
}

private func tmrPercentDisplay(_ fractionText: String) -> String {
    ((Decimal.stable(fractionText) ?? 0) * 100).stableText
}

private func tmrNumberText(_ value: Double) -> String { Decimal(value).stableText }

private func tmrFarmContext(account: AccountProfile, farm: FarmRecord) -> FarmContext {
    FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
}

private struct TMRFormulaLineInput: Identifiable, Hashable {
    var id: UUID
    var ingredientID: UUID?
    var quantityText: String

    init(id: UUID = UUID(), ingredientID: UUID? = nil, quantityText: String = "") {
        self.id = id
        self.ingredientID = ingredientID
        self.quantityText = quantityText
    }
}

struct TMRFormulaLibraryView: View {
    @Query(sort: \FeedRecipeRecord.name) private var recipes: [FeedRecipeRecord]
    @Query private var profiles: [TMRFormulaProfileRecord]

    let account: AccountProfile
    let farm: FarmRecord
    @State private var isAdding = false

    private var visibleProfiles: [TMRFormulaProfileRecord] {
        profiles.filter { $0.farmID == farm.id && $0.deletedAt == nil }
            .sorted { recipeName($0.recipeID).localizedStandardCompare(recipeName($1.recipeID)) == .orderedAscending }
    }

    var body: some View {
        List {
            if visibleProfiles.isEmpty {
                ContentUnavailableView(
                    "还没有 TMR 配方",
                    systemImage: "list.bullet.clipboard",
                    description: Text("先录入配方口径和每日原料量，再制作一锅 TMR。")
                )
            } else {
                ForEach(visibleProfiles, id: \.id) { profile in
                    if let recipe = recipe(profile.recipeID) {
                        NavigationLink {
                            TMRFormulaEditorView(account: account, farm: farm, recipe: recipe, profile: profile)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(recipe.name).font(.headline)
                                    Spacer()
                                    Text("v\(profile.formulaRevision)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                formulaSubtitleText(profile)
                                    .font(.footnote)
                                    .foregroundStyle(profile.needsReview ? Color.orange : Color.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("TMR 配方")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("新增配方", systemImage: "plus") { isAdding = true }
            }
        }
        .sheet(isPresented: $isAdding) {
            NavigationStack { TMRFormulaEditorView(account: account, farm: farm) }
        }
    }

    private func recipe(_ id: UUID) -> FeedRecipeRecord? {
        recipes.first { $0.id == id && $0.farmID == farm.id && $0.deletedAt == nil }
    }

    private func recipeName(_ id: UUID) -> String { recipe(id)?.name ?? "已停用配方" }

    @ViewBuilder
    private func formulaSubtitleText(_ profile: TMRFormulaProfileRecord) -> some View {
        if profile.needsReview {
            Text("待确认参考羊数，暂不能按羊数缩放")
        } else {
            Text(LocalizedStringKey(profile.quantityBasis.displayName))
            if let referenceHeadCount = profile.referenceHeadCount {
                Text(" · 参考 \(referenceHeadCount) 只")
            }
            Text(" · ")
            Text(LocalizedStringKey(profile.defaultScaleMode.displayName))
        }
    }
}

struct TMRFormulaEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FeedIngredientRecord.name) private var ingredients: [FeedIngredientRecord]
    @Query private var storedComponents: [FeedRecipeComponentRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let recipe: FeedRecipeRecord?
    let profile: TMRFormulaProfileRecord?
    private let commandService = FarmCommandService()

    @State private var formulaID: UUID
    @State private var name: String
    @State private var stage: FeedRecipeStage
    @State private var basis: TMRFormulaQuantityBasis
    @State private var referenceHeadCountText: String
    @State private var scaleMode: TMRFormulaScaleMode
    @State private var morningPercent: String
    @State private var noonPercent: String
    @State private var eveningPercent: String
    @State private var lines: [TMRFormulaLineInput] = [TMRFormulaLineInput()]
    @State private var note: String
    @State private var didLoadComponents = false
    @State private var didSave = false
    @State private var currentRevision: Int
    @State private var errorMessage: String?

    init(
        account: AccountProfile,
        farm: FarmRecord,
        recipe: FeedRecipeRecord? = nil,
        profile: TMRFormulaProfileRecord? = nil
    ) {
        self.account = account
        self.farm = farm
        self.recipe = recipe
        self.profile = profile
        _formulaID = State(initialValue: recipe?.id ?? UUID())
        _name = State(initialValue: recipe?.name ?? "")
        _stage = State(initialValue: recipe?.stage ?? .custom)
        _basis = State(initialValue: profile?.quantityBasis ?? .wholeGroupDaily)
        _referenceHeadCountText = State(initialValue: profile?.referenceHeadCount.map(String.init) ?? "")
        _scaleMode = State(initialValue: profile?.defaultScaleMode ?? .scaledByHeadCount)
        _morningPercent = State(initialValue: tmrPercentDisplay(profile?.morningShareText ?? "0.4"))
        _noonPercent = State(initialValue: tmrPercentDisplay(profile?.noonShareText ?? "0.35"))
        _eveningPercent = State(initialValue: tmrPercentDisplay(profile?.eveningShareText ?? "0.25"))
        _note = State(initialValue: recipe?.note ?? "")
        _currentRevision = State(initialValue: profile?.formulaRevision ?? 0)
    }

    private var farmIngredients: [FeedIngredientRecord] {
        ingredients.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive }
    }

    private var formulaTotal: Decimal {
        lines.reduce(0) { $0 + (tmrDecimal($1.quantityText) ?? 0) }
    }

    private var perHeadTotal: Decimal? {
        switch basis {
        case .perHeadDaily: return formulaTotal
        case .wholeGroupDaily:
            guard let count = Int(referenceHeadCountText), count > 0 else { return nil }
            return TMRDecimal.rounded(formulaTotal / Decimal(count))
        }
    }

    private var wholeGroupTotal: Decimal? {
        switch basis {
        case .wholeGroupDaily: return formulaTotal
        case .perHeadDaily:
            guard let count = Int(referenceHeadCountText), count > 0 else { return nil }
            return TMRDecimal.rounded(formulaTotal * Decimal(count))
        }
    }

    private var mealPercentTotal: Decimal {
        let morning = tmrDecimal(morningPercent) ?? 0
        let noon = tmrDecimal(noonPercent) ?? 0
        let evening = tmrDecimal(eveningPercent) ?? 0
        return morning + noon + evening
    }

    private var nutritionSummary: FeedRecipeNutritionSummary {
        let values = lines.compactMap { line -> FeedNutritionComponent? in
            guard let ingredientID = line.ingredientID,
                  let ingredient = farmIngredients.first(where: { $0.id == ingredientID }),
                  let kilograms = Double(line.quantityText), kilograms > 0 else { return nil }
            var nutrients = ingredient.nutrients
            if nutrients.dryMatter == nil, let dryMatter = Double(ingredient.dryMatterText ?? "") {
                nutrients.dryMatter = dryMatter
            }
            return FeedNutritionComponent(
                ingredientID: ingredient.id,
                ingredientName: ingredient.name,
                freshKilograms: kilograms,
                nutrients: nutrients
            )
        }
        return FeedRecipeNutritionSummary.calculate(components: values)
    }

    private var wholeGroupNutrition: FeedRecipeNutritionSummary? {
        switch basis {
        case .wholeGroupDaily:
            return nutritionSummary.asFedKilograms > 0 ? nutritionSummary : nil
        case .perHeadDaily:
            guard let count = Int(referenceHeadCountText), count > 0 else { return nil }
            return scaled(nutritionSummary, by: Double(count))
        }
    }

    private var perHeadNutrition: FeedRecipeNutritionSummary? {
        switch basis {
        case .wholeGroupDaily:
            return nutritionSummary.perHead(headCount: Int(referenceHeadCountText))
        case .perHeadDaily:
            return nutritionSummary.asFedKilograms > 0 ? nutritionSummary : nil
        }
    }

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("配方名称", text: $name)
                Picker("适用阶段", selection: $stage) {
                    ForEach(FeedRecipeStage.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
                TextField("参考羊数", text: $referenceHeadCountText)
                    .keyboardType(.numberPad)
                Group {
                    if basis == .wholeGroupDaily {
                        Text("整群口径必须填写参考羊数；每只量由系统换算。")
                    } else {
                        Text("参考羊数只用于同时展示参考整群总量。")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("用量口径") {
                Picker("权威口径", selection: $basis) {
                    ForEach(TMRFormulaQuantityBasis.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("默认应用方式", selection: $scaleMode) {
                    ForEach(TMRFormulaScaleMode.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
            }

            Section("原料组成") {
                ForEach($lines) { $line in
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("原料", selection: $line.ingredientID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(farmIngredients, id: \.id) { ingredient in
                                Text(ingredient.name).tag(UUID?.some(ingredient.id))
                            }
                        }
                        TextField(basis == .wholeGroupDaily ? "整群每日鲜重 kg" : "每只每日鲜重 kg", text: $line.quantityText)
                            .keyboardType(.decimalPad)
                    }
                    .swipeActions {
                        if lines.count > 1 {
                            Button(role: .destructive) { lines.removeAll { $0.id == line.id } } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                Button("添加一种原料", systemImage: "plus") { lines.append(TMRFormulaLineInput()) }
                Text("配方只关联原料品种；真实库存批次在制作 TMR 时选择。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("自动换算") {
                LabeledContent("配方录入合计") {
                    Text("\(formulaTotal.stableText) kg/日")
                }
                LabeledContent("参考整群每日量") {
                    if let wholeGroupTotal {
                        Text("\(wholeGroupTotal.stableText) kg")
                    } else {
                        Text("需填写参考羊数")
                    }
                }
                LabeledContent("每只每日量") {
                    if let perHeadTotal {
                        Text("\(perHeadTotal.stableText) kg")
                    } else {
                        Text("需填写参考羊数")
                    }
                }
                Text("非权威口径仅用于换算展示，保存时仍以所选口径为准。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("营养预览") {
                nutritionBlock("参考整群每日", summary: wholeGroupNutrition)
                nutritionBlock("每只每日", summary: perHeadNutrition)
                Text("营养值按鲜重、干物质和原料营养快照计算；缺失参数显示为“—”，不会按 0 处理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("默认顿次") {
                HStack {
                    Text("早")
                    Spacer()
                    TextField("%", text: $morningPercent).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    Text("%")
                }
                HStack {
                    Text("中")
                    Spacer()
                    TextField("%", text: $noonPercent).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    Text("%")
                }
                HStack {
                    Text("晚")
                    Spacer()
                    TextField("%", text: $eveningPercent).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    Text("%")
                }
                LabeledContent("比例合计") {
                    Text("\(mealPercentTotal.stableText)%")
                }
                Text("启用顿次的比例合计必须为 100%；全天汇总不是第四顿。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("备注") {
                TextField("配方说明", text: $note, axis: .vertical).lineLimit(2...5)
            }

            if didSave || profile != nil {
                Section("继续使用") {
                    NavigationLink {
                        TMRBatchProductionView(account: account, farm: farm, initialFormulaID: formulaID)
                    } label: {
                        Label("制作本锅", systemImage: "takeoutbag.and.cup.and.straw")
                    }
                    NavigationLink {
                        TMRFeedingPlanEditorView(account: account, farm: farm, initialFormulaID: formulaID, initialScheduleKind: .oneTime)
                    } label: {
                        Label("仅本次应用", systemImage: "calendar.badge.plus")
                    }
                    NavigationLink {
                        TMRFeedingPlanEditorView(account: account, farm: farm, initialFormulaID: formulaID, initialScheduleKind: .continuous)
                    } label: {
                        Label("设为持续投喂计划", systemImage: "calendar")
                    }
                }
            }
        }
        .navigationTitle(recipe == nil ? "新增 TMR 配方" : "编辑 TMR 配方")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .onAppear(perform: loadComponentsIfNeeded)
        .recordErrorAlert($errorMessage)
    }

    private func loadComponentsIfNeeded() {
        guard !didLoadComponents else { return }
        didLoadComponents = true
        guard let recipe else { return }
        let values = storedComponents
            .filter { $0.farmID == farm.id && $0.recipeID == recipe.id && $0.deletedAt == nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        if !values.isEmpty {
            lines = values.map { TMRFormulaLineInput(id: $0.id, ingredientID: $0.ingredientID, quantityText: $0.kilogramsText) }
        }
    }

    @ViewBuilder
    private func nutritionBlock(_ title: String, summary: FeedRecipeNutritionSummary?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title)).font(.subheadline.weight(.semibold))
            LabeledContent("鲜重") {
                if let summary { Text("\(tmrNumberText(summary.asFedKilograms)) kg") } else { Text("—") }
            }
            LabeledContent("干物质") {
                if let value = summary?.dryMatterKilograms { Text("\(tmrNumberText(value)) kg") } else { Text("—") }
            }
            LabeledContent("粗蛋白") {
                if let value = summary?.crudeProteinKilograms { Text("\(tmrNumberText(value)) kg") } else { Text("—") }
            }
            LabeledContent("NDF") {
                if let value = summary?.ndfKilograms { Text("\(tmrNumberText(value)) kg") } else { Text("—") }
            }
            LabeledContent("代谢能") {
                if let value = summary?.meMJ { Text("\(tmrNumberText(value)) MJ") } else { Text("—") }
            }
        }
    }

    private func scaled(
        _ summary: FeedRecipeNutritionSummary,
        by factor: Double
    ) -> FeedRecipeNutritionSummary {
        FeedRecipeNutritionSummary(
            asFedKilograms: summary.asFedKilograms * factor,
            dryMatterKilograms: summary.dryMatterKilograms.map { $0 * factor },
            cost: summary.cost.map { $0 * factor },
            nutrients: summary.nutrients,
            coverage: summary.coverage,
            extraCoverage: summary.extraCoverage
        )
    }

    private func save() {
        let components = lines.compactMap { line -> TMRFormulaComponentDraft? in
            guard let ingredientID = line.ingredientID else { return nil }
            return TMRFormulaComponentDraft(id: line.id, ingredientID: ingredientID, quantityText: line.quantityText)
        }
        do {
            try commandService.saveTMRFormula(
                TMRFormulaDraft(
                    id: formulaID,
                    expectedRevision: currentRevision,
                    name: name,
                    stage: stage,
                    quantityBasis: basis,
                    referenceHeadCount: Int(referenceHeadCountText),
                    defaultScaleMode: scaleMode,
                    morningShareText: tmrPercentFraction(morningPercent),
                    noonShareText: tmrPercentFraction(noonPercent),
                    eveningShareText: tmrPercentFraction(eveningPercent),
                    components: components,
                    note: note
                ),
                in: tmrFarmContext(account: account, farm: farm),
                context: modelContext
            )
            currentRevision += 1
            didSave = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TMRPlanPenInput: Identifiable, Hashable {
    let id: UUID
    let penID: UUID
    var isSelected: Bool
    var sharePercentText: String
}

struct TMRFeedingPlanLibraryView: View {
    @Query(sort: \TMRFeedingPlanRecord.effectiveStartDate, order: .reverse) private var plans: [TMRFeedingPlanRecord]
    @Query private var planPens: [TMRFeedingPlanPenRecord]

    let account: AccountProfile
    let farm: FarmRecord
    @State private var isAdding = false

    private var visiblePlans: [TMRFeedingPlanRecord] {
        plans.filter { $0.farmID == farm.id && $0.deletedAt == nil }
    }

    var body: some View {
        List {
            if visiblePlans.isEmpty {
                ContentUnavailableView(
                    "还没有 TMR 投喂计划",
                    systemImage: "calendar.badge.plus",
                    description: Text("计划定义每日目标、目标圈舍、顿次比例和监控阈值。")
                )
            } else {
                ForEach(visiblePlans, id: \.id) { plan in
                    NavigationLink {
                        TMRFeedingPlanEditorView(account: account, farm: farm, existingPlan: plan)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(plan.formulaNameSnapshot).font(.headline)
                                Spacer()
                                Text(LocalizedStringKey(plan.scheduleKind.displayName))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            planSubtitleText(plan)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            dateRangeText(plan)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle("TMR 投喂计划")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("新增计划", systemImage: "plus") { isAdding = true }
            }
        }
        .sheet(isPresented: $isAdding) {
            NavigationStack { TMRFeedingPlanEditorView(account: account, farm: farm) }
        }
    }

    private func penNames(_ planID: UUID) -> [String] {
        let names = planPens.filter { $0.farmID == farm.id && $0.planID == planID && $0.deletedAt == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.penNameSnapshot)
        return names
    }

    @ViewBuilder
    private func planSubtitleText(_ plan: TMRFeedingPlanRecord) -> some View {
        let names = penNames(plan.id)
        if names.isEmpty {
            Text("未设置圈舍")
        } else {
            Text(verbatim: names.joined(separator: "、"))
        }
        Text(" · ")
        Text(LocalizedStringKey(plan.granularity.displayName))
        Text(" · 计划 v\(plan.revision)")
    }

    @ViewBuilder
    private func dateRangeText(_ plan: TMRFeedingPlanRecord) -> some View {
        let start = plan.effectiveStartDate.formatted(date: .abbreviated, time: .omitted)
        if let end = plan.effectiveEndDate {
            let endText = end.formatted(date: .abbreviated, time: .omitted)
            if start == endText {
                Text(verbatim: start)
            } else {
                Text(verbatim: start)
                Text(" 至 ")
                Text(verbatim: endText)
            }
        } else {
            Text(verbatim: start)
            Text(" 起持续执行")
        }
    }
}

struct TMRFeedingPlanEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FeedRecipeRecord.name) private var recipes: [FeedRecipeRecord]
    @Query private var profiles: [TMRFormulaProfileRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query private var storedPlanPens: [TMRFeedingPlanPenRecord]
    @Query private var monitoringRules: [TMRMonitoringRuleRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let existingPlan: TMRFeedingPlanRecord?
    private let initialFormulaID: UUID?
    private let initialScheduleKind: TMRPlanScheduleKind
    private let commandService = FarmCommandService()

    @State private var formulaID: UUID?
    @State private var scheduleKind: TMRPlanScheduleKind
    @State private var startDate: Date
    @State private var hasEndDate: Bool
    @State private var endDate: Date
    @State private var scaleMode: TMRFormulaScaleMode
    @State private var allocationMode: TMRPenAllocationMode
    @State private var granularity: TMRMonitoringGranularity
    @State private var morningPercent: String
    @State private var noonPercent: String
    @State private var eveningPercent: String
    @State private var tolerancePercent: String
    @State private var morningTime: Date
    @State private var noonTime: Date
    @State private var eveningTime: Date
    @State private var allDayTime: Date
    @State private var monitoringEnabled: Bool
    @State private var penRows: [TMRPlanPenInput] = []
    @State private var note: String
    @State private var didLoad = false
    @State private var errorMessage: String?

    init(
        account: AccountProfile,
        farm: FarmRecord,
        initialFormulaID: UUID? = nil,
        initialScheduleKind: TMRPlanScheduleKind = .continuous,
        existingPlan: TMRFeedingPlanRecord? = nil
    ) {
        self.account = account
        self.farm = farm
        self.initialFormulaID = initialFormulaID
        self.initialScheduleKind = initialScheduleKind
        self.existingPlan = existingPlan
        let calendar = Calendar.current
        func time(_ minute: Int) -> Date {
            calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
        }
        _formulaID = State(initialValue: existingPlan?.formulaID ?? initialFormulaID)
        _scheduleKind = State(initialValue: existingPlan?.scheduleKind ?? initialScheduleKind)
        _startDate = State(initialValue: existingPlan?.effectiveStartDate ?? .now)
        _hasEndDate = State(initialValue: existingPlan?.effectiveEndDate != nil)
        _endDate = State(initialValue: existingPlan?.effectiveEndDate ?? .now)
        _scaleMode = State(initialValue: existingPlan?.scaleMode ?? .scaledByHeadCount)
        _allocationMode = State(initialValue: existingPlan?.allocationMode ?? .dynamicHeadCount)
        _granularity = State(initialValue: existingPlan?.granularity ?? .perMeal)
        _morningPercent = State(initialValue: tmrPercentDisplay(existingPlan?.morningShareText ?? "0.4"))
        _noonPercent = State(initialValue: tmrPercentDisplay(existingPlan?.noonShareText ?? "0.35"))
        _eveningPercent = State(initialValue: tmrPercentDisplay(existingPlan?.eveningShareText ?? "0.25"))
        _tolerancePercent = State(initialValue: existingPlan?.tolerancePercentText ?? "5")
        _morningTime = State(initialValue: time(existingPlan?.morningCutoffMinute ?? 540))
        _noonTime = State(initialValue: time(existingPlan?.noonCutoffMinute ?? 840))
        _eveningTime = State(initialValue: time(existingPlan?.eveningCutoffMinute ?? 1_200))
        _allDayTime = State(initialValue: time(existingPlan?.allDayCutoffMinute ?? 1_320))
        _monitoringEnabled = State(initialValue: existingPlan?.monitoringEnabled ?? true)
        _note = State(initialValue: existingPlan?.note ?? "")
    }

    private var farmProfiles: [TMRFormulaProfileRecord] {
        profiles.filter { $0.farmID == farm.id && $0.deletedAt == nil }
    }

    private var farmPens: [PenRecord] {
        pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive }
    }

    private var selectedProfile: TMRFormulaProfileRecord? {
        formulaID.flatMap { id in farmProfiles.first { $0.recipeID == id } }
    }

    private var monitoringRuleConfirmed: Bool {
        monitoringRules.contains { $0.farmID == farm.id && $0.deletedAt == nil && $0.monitoringEnabledAt != nil }
    }

    var body: some View {
        Form {
            Section("配方与日期") {
                Picker("TMR 配方", selection: $formulaID) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(farmProfiles, id: \.id) { profile in
                        Text(recipeName(profile.recipeID)).tag(UUID?.some(profile.recipeID))
                    }
                }
                Picker("计划类型", selection: $scheduleKind) {
                    ForEach(TMRPlanScheduleKind.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
                .pickerStyle(.segmented)
                DatePicker(scheduleKind == .oneTime ? "执行日期" : "开始日期", selection: $startDate, displayedComponents: .date)
                if scheduleKind == .continuous {
                    Toggle("设置结束日期", isOn: $hasEndDate)
                    if hasEndDate { DatePicker("结束日期", selection: $endDate, in: startDate..., displayedComponents: .date) }
                }
            }

            Section("目标量计算") {
                Picker("整群应用方式", selection: $scaleMode) {
                    ForEach(TMRFormulaScaleMode.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
                Picker("多舍分配", selection: $allocationMode) {
                    ForEach(TMRPenAllocationMode.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
                if selectedProfile?.needsReview == true && scaleMode == .scaledByHeadCount {
                    Text("该迁移配方缺少参考羊数，确认配方后才能按羊数缩放。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("目标圈舍") {
                ForEach($penRows) { $row in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(penName(row.penID), isOn: $row.isSelected)
                        if row.isSelected && allocationMode == .fixedShare {
                            HStack {
                                Text("固定分配")
                                Spacer()
                                TextField("%", text: $row.sharePercentText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                Text("%")
                            }
                        }
                    }
                }
                Group {
                    if allocationMode == .dynamicHeadCount {
                        Text("每天按各顿截止时间的有效羊数动态分配。")
                    } else {
                        Text("所选圈舍的固定比例合计必须为 100%。")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("监控粒度") {
                Picker("记录方式", selection: $granularity) {
                    ForEach(TMRMonitoringGranularity.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
                .pickerStyle(.segmented)
                if granularity == .perMeal {
                    percentageRow("早", value: $morningPercent)
                    percentageRow("中", value: $noonPercent)
                    percentageRow("晚", value: $eveningPercent)
                    Text("早、中、晚启用比例合计必须为 100%。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("全天汇总只比较当日总量，不生成虚构的早、中、晚目标。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("偏差阈值与截止时间") {
                percentageRow("允许偏差", value: $tolerancePercent)
                if granularity == .perMeal {
                    DatePicker("早顿截止", selection: $morningTime, displayedComponents: .hourAndMinute)
                    DatePicker("中顿截止", selection: $noonTime, displayedComponents: .hourAndMinute)
                    DatePicker("晚顿截止", selection: $eveningTime, displayedComponents: .hourAndMinute)
                } else {
                    DatePicker("全天截止", selection: $allDayTime, displayedComponents: .hourAndMinute)
                }
                Toggle("为本计划生成偏差提醒", isOn: $monitoringEnabled)
                if monitoringEnabled && !monitoringRuleConfirmed {
                    Text("牧场尚未确认 TMR 监控总开关；计划仍会显示差值，但不会自动提醒。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("备注") {
                TextField("计划说明", text: $note, axis: .vertical).lineLimit(2...5)
            }
        }
        .navigationTitle(existingPlan == nil ? "新增 TMR 计划" : "新建计划版本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .onAppear(perform: loadIfNeeded)
        .recordErrorAlert($errorMessage)
    }

    @ViewBuilder
    private func percentageRow(_ title: String, value: Binding<String>) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
            Spacer()
            TextField("%", text: value).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            Text("%")
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        let existingByPen = Dictionary(uniqueKeysWithValues: storedPlanPens.filter {
            $0.farmID == farm.id && $0.planID == existingPlan?.id && $0.deletedAt == nil
        }.map { ($0.penID, $0) })
        penRows = farmPens.map { pen in
            let existing = existingByPen[pen.id]
            return TMRPlanPenInput(
                id: existing?.id ?? UUID(),
                penID: pen.id,
                isSelected: existing != nil,
                sharePercentText: existing?.fixedShareText.map(tmrPercentDisplay) ?? ""
            )
        }
        if existingPlan == nil, formulaID == nil { formulaID = farmProfiles.first?.recipeID }
        if existingPlan == nil, let profile = selectedProfile { scaleMode = profile.defaultScaleMode }
        if existingPlan == nil,
           let rule = monitoringRules.filter({
               $0.farmID == farm.id && $0.deletedAt == nil
           }).max(by: { $0.updatedAt < $1.updatedAt }) {
            func time(_ minute: Int) -> Date {
                Calendar.current.date(
                    bySettingHour: minute / 60,
                    minute: minute % 60,
                    second: 0,
                    of: .now
                ) ?? .now
            }
            tolerancePercent = rule.tolerancePercentText
            morningTime = time(rule.morningCutoffMinute)
            noonTime = time(rule.noonCutoffMinute)
            eveningTime = time(rule.eveningCutoffMinute)
            allDayTime = time(rule.allDayCutoffMinute)
        }
    }

    private func recipeName(_ id: UUID) -> String {
        recipes.first { $0.id == id && $0.farmID == farm.id }?.name ?? "已停用配方"
    }

    private func penName(_ id: UUID) -> String {
        farmPens.first { $0.id == id }?.name ?? "历史圈舍"
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let values = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (values.hour ?? 0) * 60 + (values.minute ?? 0)
    }

    private func save() {
        guard let formulaID,
              let profile = farmProfiles.first(where: { $0.recipeID == formulaID }) else {
            errorMessage = "请选择 TMR 配方。"
            return
        }
        let selected = penRows.filter(\.isSelected)
        let drafts = selected.map {
            TMRPlanPenDraft(
                id: existingPlan == nil ? $0.id : UUID(),
                penID: $0.penID,
                fixedShareText: allocationMode == .fixedShare ? tmrPercentFraction($0.sharePercentText) : nil
            )
        }
        do {
            try commandService.saveTMRFeedingPlan(
                TMRFeedingPlanDraft(
                    supersedesPlanID: existingPlan?.id,
                    formulaID: formulaID,
                    expectedFormulaRevision: profile.formulaRevision,
                    scheduleKind: scheduleKind,
                    effectiveStartDate: startDate,
                    effectiveEndDate: scheduleKind == .continuous && hasEndDate ? endDate : nil,
                    scaleMode: scaleMode,
                    allocationMode: allocationMode,
                    granularity: granularity,
                    morningShareText: tmrPercentFraction(morningPercent),
                    noonShareText: tmrPercentFraction(noonPercent),
                    eveningShareText: tmrPercentFraction(eveningPercent),
                    tolerancePercentText: tolerancePercent,
                    morningCutoffMinute: minuteOfDay(morningTime),
                    noonCutoffMinute: minuteOfDay(noonTime),
                    eveningCutoffMinute: minuteOfDay(eveningTime),
                    allDayCutoffMinute: minuteOfDay(allDayTime),
                    monitoringEnabled: monitoringEnabled,
                    pens: drafts,
                    note: note
                ),
                in: tmrFarmContext(account: account, farm: farm),
                context: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TMRLoadInput: Identifiable, Hashable {
    var id = UUID()
    var stockBatchID: UUID?
    var actualKilogramsText: String = ""
}

private struct TMRProductionIngredientInput: Identifiable, Hashable {
    let id: UUID
    let ingredientID: UUID
    let ingredientName: String
    var plannedKilogramsText: String
    var loads: [TMRLoadInput]
}

private enum TMRProductionQuantitySource: String, CaseIterable, Identifiable {
    case customMultiplier
    case feedingPlan

    var id: Self { self }
    var displayName: String {
        switch self {
        case .customMultiplier: "自定义"
        case .feedingPlan: "按投喂计划"
        }
    }
}

private enum TMRCustomProductionInput: String, CaseIterable, Identifiable {
    case totalKilograms
    case multiplier

    var id: Self { self }
    var displayName: String {
        switch self {
        case .totalKilograms: "本锅总量"
        case .multiplier: "配方倍率"
        }
    }
}

struct TMRBatchProductionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FeedRecipeRecord.name) private var recipes: [FeedRecipeRecord]
    @Query private var profiles: [TMRFormulaProfileRecord]
    @Query private var components: [FeedRecipeComponentRecord]
    @Query(sort: \FeedIngredientRecord.name) private var ingredients: [FeedIngredientRecord]
    @Query(sort: \FeedIngredientBatchRecord.updatedAt, order: .reverse) private var stockBatches: [FeedIngredientBatchRecord]
    @Query private var stockTransactions: [FeedStockTransactionRecord]
    @Query(sort: \TMRFeedingPlanRecord.effectiveStartDate, order: .reverse) private var feedingPlans: [TMRFeedingPlanRecord]
    @Query private var planPens: [TMRFeedingPlanPenRecord]
    @Query private var sheep: [SheepRecord]
    @Query private var transfers: [TransferRecord]
    @Query private var removals: [RemovalRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let initialFormulaID: UUID?
    private let commandService = FarmCommandService()

    @State private var formulaID: UUID?
    @State private var quantitySource: TMRProductionQuantitySource = .customMultiplier
    @State private var customInput: TMRCustomProductionInput = .totalKilograms
    @State private var customTotalText = ""
    @State private var multiplierText = "1"
    @State private var planID: UUID?
    @State private var planDate = Date.now
    @State private var selectedMeals: Set<TMRMealPeriod> = []
    @State private var producedAt = Date.now
    @State private var rows: [TMRProductionIngredientInput] = []
    @State private var note = ""
    @State private var didLoad = false
    @State private var producedBatchID: UUID?
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, initialFormulaID: UUID? = nil) {
        self.account = account
        self.farm = farm
        self.initialFormulaID = initialFormulaID
        _formulaID = State(initialValue: initialFormulaID)
    }

    private var farmProfiles: [TMRFormulaProfileRecord] {
        profiles.filter { $0.farmID == farm.id && $0.deletedAt == nil && !$0.needsReview }
    }

    private var selectedProfile: TMRFormulaProfileRecord? {
        formulaID.flatMap { id in farmProfiles.first { $0.recipeID == id } }
    }

    private var farmPlans: [TMRFeedingPlanRecord] {
        feedingPlans.filter { $0.farmID == farm.id && $0.deletedAt == nil }
    }

    private var plansForSelectedDate: [TMRFeedingPlanRecord] {
        let day = TMRLocalDay.start(of: planDate, timeZone: farmTimeZone)
        return farmPlans.filter {
            $0.effectiveStartDate <= day && day <= ($0.effectiveEndDate ?? .distantFuture)
        }
    }

    private var selectedPlan: TMRFeedingPlanRecord? {
        planID.flatMap { id in farmPlans.first { $0.id == id } }
    }

    private var farmTimeZone: TimeZone {
        TimeZone(identifier: farm.timeZoneIdentifier) ?? .current
    }

    private var enabledPlanMeals: [TMRMealPeriod] {
        guard let selectedPlan else { return [] }
        if selectedPlan.granularity == .dailySummary { return [.allDaySummary] }
        return TMRMealPeriod.actualMeals.filter { selectedPlan.share(for: $0) > 0 }
    }

    private var plannedTotal: Decimal {
        rows.reduce(0) { $0 + (tmrDecimal($1.plannedKilogramsText) ?? 0) }
    }

    private var actualTotal: Decimal {
        rows.flatMap(\.loads).reduce(0) { $0 + (tmrDecimal($1.actualKilogramsText) ?? 0) }
    }

    var body: some View {
        Form {
            Section("本锅来源") {
                Picker("计算方式", selection: $quantitySource) {
                    ForEach(TMRProductionQuantitySource.allCases) { source in
                        Text(LocalizedStringKey(source.displayName)).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: quantitySource) { _, source in
                    if source == .feedingPlan {
                        configureSelectedPlan(preferCurrent: true)
                    } else {
                        planID = nil
                        selectedMeals = []
                        if formulaID == nil { formulaID = farmProfiles.first?.recipeID }
                        multiplierText = "1"
                        rebuildRows()
                        customTotalText = plannedTotal.stableText
                    }
                }

                if quantitySource == .customMultiplier {
                    Picker("TMR 配方", selection: $formulaID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(farmProfiles, id: \.id) { profile in
                            Text(recipeName(profile.recipeID)).tag(UUID?.some(profile.recipeID))
                        }
                    }
                    .onChange(of: formulaID) { _, _ in
                        rebuildRows()
                        if customInput == .totalKilograms, tmrDecimal(customTotalText) != nil {
                            applyCustomTotal()
                        } else {
                            customTotalText = plannedTotal.stableText
                        }
                    }
                    Picker("录入方式", selection: $customInput) {
                        ForEach(TMRCustomProductionInput.allCases) { input in
                            Text(LocalizedStringKey(input.displayName)).tag(input)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: customInput) { _, input in
                        if input == .totalKilograms {
                            customTotalText = plannedTotal.stableText
                        }
                    }
                    if customInput == .totalKilograms {
                        HStack {
                            Text("本锅计划总量")
                            Spacer()
                            TextField("kg", text: $customTotalText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("kg")
                        }
                        .onChange(of: customTotalText) { _, _ in applyCustomTotal() }
                    } else {
                        HStack {
                            Text("配方倍率")
                            Spacer()
                            TextField("倍", text: $multiplierText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                        .onChange(of: multiplierText) { _, _ in
                            updatePlannedAmounts()
                            customTotalText = plannedTotal.stableText
                        }
                    }
                } else {
                    DatePicker("计划日期", selection: $planDate, displayedComponents: .date)
                        .onChange(of: planDate) { _, _ in configureSelectedPlan(preferCurrent: true) }
                    Picker("投喂计划", selection: $planID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(plansForSelectedDate, id: \.id) { plan in
                            HStack(spacing: 0) {
                                Text(verbatim: plan.formulaNameSnapshot)
                                Text(" · ")
                                Text(LocalizedStringKey(plan.granularity.displayName))
                            }
                            .tag(UUID?.some(plan.id))
                        }
                    }
                    .onChange(of: planID) { _, _ in configureSelectedPlan(preferCurrent: false) }
                    if let selectedPlan {
                        LabeledContent("计划快照") {
                            Text("\(selectedPlan.formulaNameSnapshot) v\(selectedPlan.formulaRevision)")
                        }
                        if selectedPlan.granularity == .dailySummary {
                            LabeledContent("计算范围") { Text("全天计划") }
                        } else {
                            ForEach(enabledPlanMeals, id: \.self) { meal in
                                Toggle(isOn: mealSelection(meal)) {
                                    mealShareText(meal, plan: selectedPlan)
                                }
                            }
                            Button("选择全部顿次", systemImage: "checkmark.circle") {
                                selectedMeals = Set(enabledPlanMeals)
                                applyPlanSuggestion()
                            }
                        }
                        if let total = try? suggestedPlanTotal() {
                            LabeledContent("本锅建议量") {
                                Text("\(total.stableText) kg")
                            }
                            LabeledContent("计算倍率") {
                                Text("\(multiplierText) 倍")
                            }
                            if !selectedMeals.isEmpty {
                                planHeadCountSummaryText
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("当前日期、圈舍羊数或顿次选择不足，暂时无法计算建议量。")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    } else if plansForSelectedDate.isEmpty {
                        Text("所选日期没有有效的 TMR 投喂计划。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                DatePicker("制作时间", selection: $producedAt)
                Text("按计划选择多顿只是本锅产量计算快捷方式，不会生成“全天汇总”投喂记录；实际投喂仍逐顿、逐舍录入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach($rows) { $row in
                Section(row.ingredientName) {
                    LabeledContent("计划装入") {
                        Text("\(row.plannedKilogramsText) kg")
                    }
                    ForEach($row.loads) { $load in
                        Picker("库存批次", selection: $load.stockBatchID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(availableStockBatches(ingredientID: row.ingredientID), id: \.id) { batch in
                                Text("\(batch.batchName) · 余 \(stockBalance(batch).stableText) kg")
                                    .tag(UUID?.some(batch.id))
                            }
                        }
                        HStack {
                            Text("实际装入")
                            Spacer()
                            TextField("kg", text: $load.actualKilogramsText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("kg")
                        }
                        .swipeActions {
                            if row.loads.count > 1 {
                                Button(role: .destructive) { row.loads.removeAll { $0.id == load.id } } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    Button("拆用另一个库存批次", systemImage: "plus") {
                        row.loads.append(TMRLoadInput())
                    }
                }
            }

            Section("成锅汇总") {
                LabeledContent("计划装入合计") {
                    Text("\(plannedTotal.stableText) kg")
                }
                LabeledContent("实际成锅重量") {
                    Text("\(actualTotal.stableText) kg")
                }
                Text("成锅重量自动等于各原料实际装入量合计，无需再次填写成品过磅值。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("制作备注", text: $note, axis: .vertical).lineLimit(2...5)
            }

            if let producedBatchID {
                Section("下一步") {
                    NavigationLink {
                        TMRFeedingEntryView(account: account, farm: farm, initialBatchID: producedBatchID)
                    } label: {
                        Label("从本批次投喂", systemImage: "arrow.right.circle")
                    }
                    NavigationLink {
                        TMRBatchDetailView(account: account, farm: farm, batchID: producedBatchID)
                    } label: {
                        Label("查看批次详情", systemImage: "list.bullet.rectangle")
                    }
                }
            }
        }
        .navigationTitle("制作 TMR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存成锅", action: produce).disabled(producedBatchID != nil)
            }
        }
        .onAppear(perform: loadIfNeeded)
        .recordErrorAlert($errorMessage)
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if formulaID == nil { formulaID = farmProfiles.first?.recipeID }
        rebuildRows()
        customTotalText = plannedTotal.stableText
    }

    private func configureSelectedPlan(preferCurrent: Bool) {
        guard quantitySource == .feedingPlan else { return }
        if preferCurrent, !plansForSelectedDate.contains(where: { $0.id == planID }) {
            planID = plansForSelectedDate.first?.id
        }
        guard let plan = selectedPlan,
              plansForSelectedDate.contains(where: { $0.id == plan.id }) else {
            formulaID = nil
            selectedMeals = []
            rows = []
            return
        }
        formulaID = plan.formulaID
        selectedMeals = Set(plan.granularity == .dailySummary ? [.allDaySummary] : enabledPlanMeals)
        applyPlanSuggestion()
    }

    private func mealSelection(_ meal: TMRMealPeriod) -> Binding<Bool> {
        Binding(
            get: { selectedMeals.contains(meal) },
            set: { isSelected in
                if isSelected { selectedMeals.insert(meal) } else { selectedMeals.remove(meal) }
                applyPlanSuggestion()
            }
        )
    }

    private func applyPlanSuggestion() {
        guard let plan = selectedPlan,
              let total = try? suggestedPlanTotal(),
              plan.formulaDailyTotalKilograms > 0 else {
            multiplierText = ""
            rows = []
            return
        }
        formulaID = plan.formulaID
        multiplierText = TMRDecimal.rounded(total / plan.formulaDailyTotalKilograms, scale: 6).stableText
        rebuildRows()
    }

    private func suggestedPlanTotal() throws -> Decimal {
        guard let plan = selectedPlan else { throw TMRCommandApplyError.planNotFound }
        let meals = selectedMeals.sorted { $0.sortOrder < $1.sortOrder }
        guard !meals.isEmpty else { throw TMRCommandApplyError.planMealMismatch }
        let selectedPens = planPens.filter {
            $0.farmID == farm.id && $0.planID == plan.id && $0.deletedAt == nil
        }
        guard !selectedPens.isEmpty else { throw TMRDomainError.emptyPens }
        let occupancy = FarmPenOccupancyIndex.make(
            farmID: farm.id,
            sheep: sheep,
            transfers: transfers,
            removals: removals
        )
        let day = TMRLocalDay.start(of: planDate, timeZone: farmTimeZone)
        var result = Decimal.zero
        for meal in meals {
            let cutoff = TMRLocalDay.cutoff(
                for: day,
                minuteOfDay: plan.cutoffMinute(for: meal),
                timeZone: farmTimeZone
            )
            let headCounts = occupancy.sheepIDsByPen(at: cutoff).mapValues(\.count)
            let totalHeads = selectedPens.reduce(0) { $0 + headCounts[$1.penID, default: 0] }
            let dailyTarget = try TMRCalculator.targetGroupDailyTotal(
                formulaDailyTotal: plan.formulaDailyTotalKilograms,
                basis: plan.quantityBasis,
                scaleMode: plan.scaleMode,
                referenceHeadCount: plan.referenceHeadCountSnapshot,
                targetHeadCount: totalHeads
            )
            result += TMRCalculator.mealTarget(
                dailyTarget: dailyTarget,
                meal: meal,
                shares: try TMRMealShares(
                    morning: plan.share(for: .morning),
                    noon: plan.share(for: .noon),
                    evening: plan.share(for: .evening)
                )
            )
        }
        guard result > 0 else { throw TMRDomainError.nonPositiveQuantity }
        return TMRDecimal.rounded(result)
    }

    @ViewBuilder
    private var planHeadCountSummaryText: some View {
        if let plan = selectedPlan {
            let selectedPens = planPens.filter {
                $0.farmID == farm.id && $0.planID == plan.id && $0.deletedAt == nil
            }
            let occupancy = FarmPenOccupancyIndex.make(farmID: farm.id, sheep: sheep, transfers: transfers, removals: removals)
            let day = TMRLocalDay.start(of: planDate, timeZone: farmTimeZone)
            let summaries = selectedMeals.sorted { $0.sortOrder < $1.sortOrder }.map { meal in
                let cutoff = TMRLocalDay.cutoff(for: day, minuteOfDay: plan.cutoffMinute(for: meal), timeZone: farmTimeZone)
                let counts = occupancy.sheepIDsByPen(at: cutoff).mapValues(\.count)
                let total = selectedPens.reduce(0) { $0 + counts[$1.penID, default: 0] }
                return (meal: meal, count: total)
            }
            ForEach(Array(summaries.enumerated()), id: \.offset) { index, summary in
                if index > 0 { Text("；") }
                Text(LocalizedStringKey(summary.meal.displayName))
                Text("顿按 \(summary.count) 只计算")
            }
        }
    }

    @ViewBuilder
    private func mealShareText(_ meal: TMRMealPeriod, plan: TMRFeedingPlanRecord) -> some View {
        Text(LocalizedStringKey(meal.displayName))
        Text("顿（\(tmrPercentDisplay(plan.share(for: meal).stableText))%）")
    }

    private func rebuildRows() {
        guard let formulaID else { rows = []; return }
        let ingredientByID = Dictionary(uniqueKeysWithValues: ingredients.filter {
            $0.farmID == farm.id && $0.deletedAt == nil
        }.map { ($0.id, $0) })
        let multiplier = tmrDecimal(multiplierText) ?? 0
        let sourceComponents: [TMRFormulaComponentSnapshot]
        if quantitySource == .feedingPlan, let plan = selectedPlan {
            sourceComponents = plan.componentSnapshot
        } else {
            sourceComponents = components.filter {
                $0.farmID == farm.id && $0.recipeID == formulaID && $0.deletedAt == nil
            }.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { component in
                guard let ingredient = ingredientByID[component.ingredientID] else { return nil }
                return TMRFormulaComponentSnapshot(
                    id: component.id,
                    ingredientID: ingredient.id,
                    ingredientName: ingredient.name,
                    quantityText: component.kilogramsText,
                    unit: ingredient.unit,
                    pricePerKilogramText: component.pricePerKilogramText,
                    nutrientSnapshotJSON: component.nutrientSnapshotJSON,
                    dryMatterText: ingredient.dryMatterText
                )
            }
        }
        rows = sourceComponents.compactMap { component in
            guard let ingredient = ingredientByID[component.ingredientID] else { return nil }
            let planned = TMRDecimal.rounded(component.quantity * multiplier)
            let defaultBatch = availableStockBatches(ingredientID: ingredient.id).first
            return TMRProductionIngredientInput(
                id: component.id,
                ingredientID: ingredient.id,
                ingredientName: ingredient.name,
                plannedKilogramsText: planned.stableText,
                loads: [TMRLoadInput(stockBatchID: defaultBatch?.id, actualKilogramsText: planned.stableText)]
            )
        }
    }

    private func updatePlannedAmounts() {
        let multiplier = tmrDecimal(multiplierText) ?? 0
        let componentByIngredient: [UUID: Decimal]
        if quantitySource == .feedingPlan, let plan = selectedPlan {
            componentByIngredient = Dictionary(uniqueKeysWithValues: plan.componentSnapshot.map { ($0.ingredientID, $0.quantity) })
        } else if let formulaID {
            componentByIngredient = Dictionary(uniqueKeysWithValues: components.filter {
                $0.farmID == farm.id && $0.recipeID == formulaID && $0.deletedAt == nil
            }.map { ($0.ingredientID, Decimal.stable($0.kilogramsText) ?? 0) })
        } else {
            return
        }
        for index in rows.indices {
            guard let quantity = componentByIngredient[rows[index].ingredientID] else { continue }
            let planned = TMRDecimal.rounded(quantity * multiplier)
            rows[index].plannedKilogramsText = planned.stableText
            if rows[index].loads.count == 1 { rows[index].loads[0].actualKilogramsText = planned.stableText }
        }
    }

    private func applyCustomTotal() {
        guard quantitySource == .customMultiplier,
              customInput == .totalKilograms,
              let total = tmrDecimal(customTotalText), total > 0,
              let formulaID else { return }
        let quantitiesByIngredient = Dictionary(uniqueKeysWithValues: components.filter {
            $0.farmID == farm.id && $0.recipeID == formulaID && $0.deletedAt == nil
        }.map { ($0.ingredientID, Decimal.stable($0.kilogramsText) ?? 0) })
        let quantities = rows.map { quantitiesByIngredient[$0.ingredientID] ?? 0 }
        let formulaTotal = TMRDecimal.rounded(quantities.reduce(Decimal.zero, +))
        guard quantities.allSatisfy({ $0 > 0 }), formulaTotal > 0,
              let amounts = try? TMRCalculator.proportionalAmounts(
                  totalKilograms: total,
                  componentQuantities: quantities
              ) else { return }
        multiplierText = TMRDecimal.rounded(total / formulaTotal, scale: 6).stableText
        for index in rows.indices {
            rows[index].plannedKilogramsText = amounts[index].stableText
            if rows[index].loads.count == 1 {
                rows[index].loads[0].actualKilogramsText = amounts[index].stableText
            }
        }
    }

    private func availableStockBatches(ingredientID: UUID) -> [FeedIngredientBatchRecord] {
        stockBatches.filter {
            $0.farmID == farm.id && $0.ingredientID == ingredientID && $0.deletedAt == nil && $0.isActive
        }
    }

    private func stockBalance(_ batch: FeedIngredientBatchRecord) -> Decimal {
        FeedStockLedger.balance(for: batch, transactions: stockTransactions) ?? 0
    }

    private func recipeName(_ id: UUID) -> String {
        recipes.first { $0.id == id && $0.farmID == farm.id }?.name ?? "已停用配方"
    }

    private func produce() {
        guard let formulaID else {
            errorMessage = "请选择已经确认的 TMR 配方。"
            return
        }
        let expectedFormulaRevision: Int
        let sourcePlan: TMRFeedingPlanRecord?
        if quantitySource == .feedingPlan {
            guard let plan = selectedPlan,
                  let suggested = try? suggestedPlanTotal(), suggested > 0 else {
                errorMessage = "请选择有效计划、日期和至少一个顿次。"
                return
            }
            expectedFormulaRevision = plan.formulaRevision
            sourcePlan = plan
        } else {
            guard let profile = selectedProfile else {
                errorMessage = "请选择已经确认的 TMR 配方。"
                return
            }
            if customInput == .totalKilograms {
                guard let total = tmrDecimal(customTotalText), total > 0,
                      plannedTotal == TMRDecimal.rounded(total) else {
                    errorMessage = "请输入有效的本锅计划总量。"
                    return
                }
            } else {
                guard let multiplier = tmrDecimal(multiplierText), multiplier > 0 else {
                    errorMessage = "请输入大于 0 的配方倍率。"
                    return
                }
            }
            expectedFormulaRevision = profile.formulaRevision
            sourcePlan = nil
        }
        let drafts = rows.map { row in
            TMRBatchIngredientDraft(
                id: UUID(),
                ingredientID: row.ingredientID,
                plannedKilogramsText: row.plannedKilogramsText,
                loadLines: row.loads.compactMap { load in
                    guard let stockBatchID = load.stockBatchID else { return nil }
                    return TMRBatchLoadDraft(id: load.id, ingredientBatchID: stockBatchID, actualKilogramsText: load.actualKilogramsText)
                }
            )
        }
        let batchID = UUID()
        do {
            try commandService.produceTMRBatch(
                TMRBatchProductionDraft(
                    id: batchID,
                    formulaID: formulaID,
                    expectedFormulaRevision: expectedFormulaRevision,
                    sourcePlanID: sourcePlan?.id,
                    sourcePlanRevision: sourcePlan?.revision,
                    sourcePlanDate: sourcePlan == nil ? nil : planDate,
                    sourceMeals: sourcePlan == nil ? nil : selectedMeals.sorted { $0.sortOrder < $1.sortOrder },
                    producedAt: producedAt,
                    ingredients: drafts,
                    note: note
                ),
                in: tmrFarmContext(account: account, farm: farm),
                context: modelContext
            )
            producedBatchID = batchID
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct TMRBatchLibraryView: View {
    @Query(sort: \TMRBatchRecord.producedAt, order: .reverse) private var batches: [TMRBatchRecord]
    @Query private var movements: [TMRBatchMovementRecord]

    let account: AccountProfile
    let farm: FarmRecord

    private var visibleBatches: [TMRBatchRecord] {
        batches.filter { $0.farmID == farm.id && $0.deletedAt == nil }
    }

    var body: some View {
        List {
            if visibleBatches.isEmpty {
                ContentUnavailableView(
                    "还没有 TMR 批次",
                    systemImage: "takeoutbag.and.cup.and.straw",
                    description: Text("制作一锅 TMR 后会在这里形成成品账。")
                )
            } else {
                ForEach(visibleBatches, id: \.id) { batch in
                    NavigationLink {
                        TMRBatchDetailView(account: account, farm: farm, batchID: batch.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(batch.batchCode).font(.headline.monospacedDigit())
                                Spacer()
                                Text(LocalizedStringKey(batch.status.displayName))
                                    .font(.caption)
                                    .foregroundStyle(batch.status == .available ? Color.green : Color.secondary)
                            }
                            Text("\(batch.formulaNameSnapshot) v\(batch.formulaRevision) · 产量 \(batch.producedKilogramsText) kg")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("剩余 \(balance(batch.id).stableText) kg · \(batch.producedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle("TMR 批次")
    }

    private func balance(_ batchID: UUID) -> Decimal {
        TMRCalculator.batchBalance(movements: movements.filter { $0.batchID == batchID })
    }
}

struct TMRBatchDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var batches: [TMRBatchRecord]
    @Query private var ingredients: [TMRBatchIngredientRecord]
    @Query private var loads: [TMRBatchLoadLineRecord]
    @Query(sort: \TMRBatchMovementRecord.occurredAt, order: .reverse) private var movements: [TMRBatchMovementRecord]
    @Query private var feedingRuns: [TMRFeedingRunRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let batchID: UUID
    private let commandService = FarmCommandService()
    @State private var reason = ""
    @State private var isAdjusting = false
    @State private var errorMessage: String?

    private var batch: TMRBatchRecord? {
        batches.first { $0.id == batchID && $0.farmID == farm.id }
    }

    private var batchIngredients: [TMRBatchIngredientRecord] {
        ingredients.filter { $0.batchID == batchID && $0.deletedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var batchMovements: [TMRBatchMovementRecord] {
        movements.filter { $0.batchID == batchID && $0.deletedAt == nil }
    }

    private var balance: Decimal { TMRCalculator.batchBalance(movements: batchMovements) }

    private var hasFeedingHistory: Bool {
        feedingRuns.contains { $0.farmID == farm.id && $0.batchID == batchID && $0.deletedAt == nil }
    }

    var body: some View {
        List {
            if let batch {
                Section("批次") {
                    LabeledContent("批次号", value: batch.batchCode)
                    LabeledContent("配方", value: "\(batch.formulaNameSnapshot) v\(batch.formulaRevision)")
                    if batch.sourcePlanID != nil {
                        LabeledContent("生产来源") {
                            Text("投喂计划 v\(batch.sourcePlanRevision ?? 0)")
                        }
                        if let sourcePlanDate = batch.sourcePlanDate {
                            LabeledContent("计划日期", value: sourcePlanDate.formatted(date: .abbreviated, time: .omitted))
                        }
                        LabeledContent("计划顿次") {
                            HStack(spacing: 4) {
                                ForEach(Array(batch.sourcePlanMeals.enumerated()), id: \.offset) { index, meal in
                                    if index > 0 { Text("、") }
                                    Text(LocalizedStringKey(meal.displayName))
                                }
                            }
                        }
                    } else {
                        LabeledContent("生产来源") {
                            Text("自定义配方倍率")
                        }
                    }
                    LabeledContent("制作时间", value: batch.producedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("生产量") {
                        Text("\(batch.producedKilogramsText) kg")
                    }
                    LabeledContent("当前余额") {
                        Text("\(balance.stableText) kg")
                    }
                    LabeledContent("状态") {
                        Text(LocalizedStringKey(batch.status.displayName))
                    }
                }
                Section("实际装料") {
                    ForEach(batchIngredients, id: \.id) { ingredient in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(ingredient.ingredientNameSnapshot)
                                Spacer()
                                Text("\(ingredient.actualKilogramsText) kg")
                            }
                            HStack(spacing: 0) {
                                Text("计划 \(ingredient.plannedKilogramsText) kg")
                                if let loadDescription = loadDescription(ingredient.id) {
                                    Text(" · ")
                                    Text(verbatim: loadDescription)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("成品流水") {
                    ForEach(batchMovements, id: \.id) { movement in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(LocalizedStringKey(movement.kind.displayName))
                                Text(movement.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(movementDeltaText(movement))
                                .monospacedDigit()
                        }
                    }
                }
                if batch.status == .available && balance > 0 {
                    Section("投喂") {
                        NavigationLink {
                            TMRFeedingEntryView(account: account, farm: farm, initialBatchID: batch.id)
                        } label: {
                            Label("从本批次投喂", systemImage: "arrow.right.circle")
                        }
                    }
                }
                if batch.status != .closed {
                    Section("批次管理") {
                        Button("调整批次余额", systemImage: "plusminus.circle") { isAdjusting = true }
                        TextField("结清或删除原因", text: $reason, axis: .vertical).lineLimit(2...4)
                        if balance > 0 {
                            Button("报废余额并结清", role: .destructive) { close(batch, waste: true) }
                        } else {
                            Button("结清批次") { close(batch, waste: false) }
                        }
                    }
                }
                if batch.status != .closed && !hasFeedingHistory {
                    Section {
                        Button("删除未使用的整锅并冲回原料", role: .destructive) { deleteUnused(batch) }
                    } footer: {
                        Text("只允许删除没有任何下游投喂的批次；原料库存以反向流水完整冲回。")
                    }
                }
            } else {
                ContentUnavailableView("批次不存在", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(batch?.batchCode ?? "TMR 批次")
        .sheet(isPresented: $isAdjusting) {
            NavigationStack {
                TMRBatchAdjustmentView(account: account, farm: farm, batchID: batchID)
            }
        }
        .recordErrorAlert($errorMessage)
    }

    private func loadDescription(_ batchIngredientID: UUID) -> String? {
        let names = loads.filter { $0.batchIngredientID == batchIngredientID && $0.deletedAt == nil }
            .map { "\($0.ingredientBatchNameSnapshot) \($0.actualKilogramsText) kg" }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private func movementDeltaText(_ movement: TMRBatchMovementRecord) -> String {
        let prefix = movement.deltaKilograms >= 0 ? "+" : ""
        return "\(prefix)\(movement.deltaKilogramsText) kg"
    }

    private func close(_ batch: TMRBatchRecord, waste: Bool) {
        do {
            try commandService.closeTMRBatch(
                TMRBatchCloseDraft(batchID: batch.id, expectedBatchRevision: batch.revision, wasteRemaining: waste, reason: reason),
                in: tmrFarmContext(account: account, farm: farm),
                context: modelContext
            )
        } catch { errorMessage = error.localizedDescription }
    }

    private func deleteUnused(_ batch: TMRBatchRecord) {
        do {
            try commandService.deleteUnusedTMRBatch(
                TMRBatchDeletionDraft(batchID: batch.id, expectedBatchRevision: batch.revision, reason: reason),
                in: tmrFarmContext(account: account, farm: farm),
                context: modelContext
            )
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct TMRBatchAdjustmentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var batches: [TMRBatchRecord]
    @Query private var movements: [TMRBatchMovementRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let batchID: UUID
    private let commandService = FarmCommandService()

    @State private var deltaText = ""
    @State private var occurredAt = Date.now
    @State private var reason = ""
    @State private var errorMessage: String?

    private var batch: TMRBatchRecord? {
        batches.first { $0.id == batchID && $0.farmID == farm.id && $0.deletedAt == nil }
    }

    private var currentBalance: Decimal {
        TMRCalculator.batchBalance(movements: movements.filter {
            $0.farmID == farm.id && $0.batchID == batchID && $0.deletedAt == nil
        })
    }

    private var adjustedBalance: Decimal? {
        tmrDecimal(deltaText).map { TMRDecimal.rounded(currentBalance + $0) }
    }

    var body: some View {
        Form {
            Section("批次余额") {
                LabeledContent("当前余额") {
                    Text("\(currentBalance.stableText) kg")
                }
                HStack {
                    Text("调整量")
                    Spacer()
                    TextField("例如 -2 或 1.5", text: $deltaText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                    Text("kg")
                }
                LabeledContent("调整后余额") {
                    if let adjustedBalance {
                        Text("\(adjustedBalance.stableText) kg")
                    } else {
                        Text("—")
                    }
                }
                Text("正数增加、负数减少；余额不能小于 0。调整只影响 TMR 成品账，不改动原料库存。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("审计信息") {
                DatePicker("发生时间", selection: $occurredAt)
                TextField("必填调整原因", text: $reason, axis: .vertical).lineLimit(2...5)
            }
        }
        .navigationTitle("调整 TMR 批次")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        guard let batch else { errorMessage = "批次不存在或已更新。"; return }
        do {
            try commandService.adjustTMRBatch(
                TMRBatchAdjustmentDraft(
                    batchID: batch.id,
                    expectedBatchRevision: batch.revision,
                    deltaKilogramsText: deltaText,
                    occurredAt: occurredAt,
                    reason: reason
                ),
                in: tmrFarmContext(account: account, farm: farm),
                context: modelContext
            )
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct TMRFeedPenInput: Identifiable, Hashable {
    let id: UUID
    let penID: UUID
    let penName: String
    var isSelected: Bool
    var headCountText: String
    var actualKilogramsText: String
}

struct TMRFeedingEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TMRBatchRecord.producedAt, order: .reverse) private var batches: [TMRBatchRecord]
    @Query private var movements: [TMRBatchMovementRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let initialBatchID: UUID?
    private let commandService = FarmCommandService()

    @State private var batchID: UUID?
    @State private var occurredAt = Date.now
    @State private var meal: TMRMealPeriod = .morning
    @State private var totalKilogramsText = ""
    @State private var penRows: [TMRFeedPenInput] = []
    @State private var monitorRows: [TMRMonitoringRow] = []
    @State private var didLoad = false
    @State private var note = ""
    @State private var isSaving = false
    @State private var pendingReopenDraft: TMRFeedingRunDraft?
    @State private var showingReopenConfirmation = false
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, initialBatchID: UUID? = nil) {
        self.account = account
        self.farm = farm
        self.initialBatchID = initialBatchID
        _batchID = State(initialValue: initialBatchID)
    }

    private var farmBatches: [TMRBatchRecord] {
        batches.filter {
            $0.farmID == farm.id && $0.deletedAt == nil && $0.status == .available && batchBalance($0.id) > 0
        }
    }

    private var selectedBatch: TMRBatchRecord? {
        batchID.flatMap { id in farmBatches.first { $0.id == id } }
    }

    private var selectedRows: [TMRFeedPenInput] { penRows.filter(\.isSelected) }

    private var actualTotal: Decimal {
        selectedRows.reduce(0) { $0 + (tmrDecimal($1.actualKilogramsText) ?? 0) }
    }

    private var monitorTaskID: String {
        "\(batchID?.uuidString ?? "none"):\(occurredAt.timeIntervalSince1970):\(meal.rawValue)"
    }

    var body: some View {
        Form {
            Section("出锅投喂") {
                Picker("TMR 批次", selection: $batchID) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(farmBatches, id: \.id) { batch in
                        Text("\(batch.batchCode) · 余 \(batchBalance(batch.id).stableText) kg")
                            .tag(UUID?.some(batch.id))
                    }
                }
                DatePicker("投喂时间", selection: $occurredAt)
                Picker("顿次", selection: $meal) {
                    ForEach(TMRMealPeriod.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
                .pickerStyle(.segmented)
                if meal == .allDaySummary {
                    Text("全天汇总表示当天总投料、不区分顿次；同一计划、圈舍和日期不能再录早、中、晚。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("按总量分配") {
                HStack {
                    Text("本次总量")
                    Spacer()
                    TextField("kg", text: $totalKilogramsText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("kg")
                }
                Button("按所选圈舍有效羊数分配", systemImage: "person.2") { distributeTotal() }
                Text("分配后仍可逐舍调整；保存时以逐舍实际量合计为准。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("目标圈舍与实际投喂") {
                ForEach($penRows) { $row in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(row.penName, isOn: $row.isSelected)
                        if row.isSelected {
                            HStack {
                                Text("有效羊数")
                                Spacer()
                                TextField("只", text: $row.headCountText)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                Text("只")
                            }
                            HStack {
                                Text("实际投喂")
                                Spacer()
                                TextField("kg", text: $row.actualKilogramsText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                Text("kg")
                            }
                            if let target = targetRow(penID: row.penID) {
                                HStack {
                                    Text("计划目标")
                                    Spacer()
                                    Text(target.targetKilograms.map { "\($0.stableText) kg" } ?? "无法计算")
                                        .foregroundStyle(.secondary)
                                }
                                if target.formulaRevision != selectedBatch?.formulaRevision {
                                    Text("本批次配方修订 v\(selectedBatch?.formulaRevision ?? 0)，计划快照 v\(target.formulaRevision)；同一配方可计入，但请核对版本差异。")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                if target.isCompleted {
                                    Text("该顿已手工完成；保存追加投料时会先要求确认重新打开本顿。")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            } else {
                                Text("没有匹配的有效计划，将记为计划外投喂。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("保存前核对") {
                LabeledContent("批次当前余额") {
                    if let selectedBatch {
                        Text("\(batchBalance(selectedBatch.id).stableText) kg")
                    } else {
                        Text("—")
                    }
                }
                LabeledContent("本次实际合计") {
                    Text("\(actualTotal.stableText) kg")
                }
                LabeledContent("投后余额") {
                    if let selectedBatch {
                        Text("\(TMRDecimal.rounded(batchBalance(selectedBatch.id) - actualTotal).stableText) kg")
                    } else {
                        Text("—")
                    }
                }
                TextField("投喂备注", text: $note, axis: .vertical).lineLimit(2...5)
            }
        }
        .navigationTitle("记录 TMR 投喂")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save).disabled(isSaving)
            }
        }
        .onAppear(perform: loadIfNeeded)
        .task(id: monitorTaskID) { await loadTargetsAndHeadCounts() }
        .confirmationDialog(
            "重新打开已完成顿次？",
            isPresented: $showingReopenConfirmation,
            titleVisibility: .visible
        ) {
            Button("重新打开并保存") {
                guard let draft = pendingReopenDraft else { return }
                pendingReopenDraft = nil
                performSave(draft)
            }
            Button("取消", role: .cancel) { pendingReopenDraft = nil }
        } message: {
            Text("本次追加涉及已手工完成的圈舍顿次。确认后，重新打开与追加投料会作为同一个原子操作保存。")
        }
        .recordErrorAlert($errorMessage)
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if batchID == nil { batchID = farmBatches.first?.id }
        penRows = pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive }.map {
            TMRFeedPenInput(id: UUID(), penID: $0.id, penName: $0.name, isSelected: false, headCountText: "", actualKilogramsText: "")
        }
    }

    @MainActor
    private func loadTargetsAndHeadCounts() async {
        guard let selectedBatch else { monitorRows = []; return }
        do {
            let snapshot = try await TMRMonitoringReadActor(container: modelContext.container).load(
                farmID: farm.id,
                localDay: occurredAt,
                filter: TMRMonitoringFilter(formulaID: selectedBatch.formulaID),
                now: occurredAt
            )
            let eligibility = try await FeedPenEligibilityReadActor(container: modelContext.container)
                .load(farmID: farm.id, on: occurredAt)
            try Task.checkCancellation()
            monitorRows = snapshot.rows.filter { $0.meal == meal }
            for index in penRows.indices where penRows[index].headCountText.isEmpty {
                penRows[index].headCountText = String(eligibility.sheepByPen[penRows[index].penID]?.count ?? 0)
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "计划目标读取失败：\(error.localizedDescription)"
        }
    }

    private func targetRow(penID: UUID) -> TMRMonitoringRow? {
        monitorRows.first { $0.penID == penID && $0.meal == meal }
    }

    private func distributeTotal() {
        guard let total = tmrDecimal(totalKilogramsText), total > 0 else {
            errorMessage = "请输入大于 0 的本次总量。"
            return
        }
        let selected = penRows.indices.filter { penRows[$0].isSelected }
        let inputs = selected.map {
            TMRPenAllocationInput(id: penRows[$0].penID, headCount: Int(penRows[$0].headCountText) ?? 0)
        }
        do {
            let allocations = try TMRCalculator.allocateToPens(totalKilograms: total, inputs: inputs, mode: .dynamicHeadCount)
            let byPen = Dictionary(uniqueKeysWithValues: allocations.map { ($0.id, $0.kilograms) })
            for index in selected { penRows[index].actualKilogramsText = byPen[penRows[index].penID]?.stableText ?? "" }
        } catch { errorMessage = error.localizedDescription }
    }

    private func batchBalance(_ id: UUID) -> Decimal {
        TMRCalculator.batchBalance(movements: movements.filter { $0.batchID == id })
    }

    private func save() {
        guard let batch = selectedBatch else { errorMessage = "请选择有余额的 TMR 批次。"; return }
        let allocations = selectedRows.compactMap { row -> TMRFeedingAllocationDraft? in
            guard let actual = tmrDecimal(row.actualKilogramsText), actual > 0 else { return nil }
            let target = targetRow(penID: row.penID)
            return TMRFeedingAllocationDraft(
                penID: row.penID,
                planID: target?.planID,
                planRevision: target?.planRevision,
                actualHeadCountSnapshot: Int(row.headCountText) ?? 0,
                actualKilogramsText: actual.stableText,
                targetKilogramsTextSnapshot: target?.targetKilograms?.stableText
            )
        }
        let reopenCompletions = selectedRows.compactMap { row -> TMRMealReopenDraft? in
            guard let actual = tmrDecimal(row.actualKilogramsText), actual > 0,
                  let target = targetRow(penID: row.penID),
                  target.isCompleted,
                  let completionID = target.completionID else { return nil }
            return TMRMealReopenDraft(
                completionID: completionID,
                reason: "追加本顿 TMR 投料"
            )
        }
        let draft = TMRFeedingRunDraft(
            batchID: batch.id,
            expectedBatchRevision: batch.revision,
            occurredAt: occurredAt,
            meal: meal,
            allocations: allocations,
            reopenCompletions: reopenCompletions.isEmpty ? nil : reopenCompletions,
            note: note
        )
        if !reopenCompletions.isEmpty {
            pendingReopenDraft = draft
            showingReopenConfirmation = true
            return
        }
        performSave(draft)
    }

    private func performSave(_ draft: TMRFeedingRunDraft) {
        isSaving = true
        defer { isSaving = false }
        do {
            try commandService.recordTMRFeeding(
                draft,
                in: tmrFarmContext(account: account, farm: farm),
                context: modelContext
            )
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct TMRFeedingCorrectionPenInput: Identifiable, Hashable {
    let id: UUID
    let penID: UUID
    let penName: String
    let planID: UUID?
    let planRevision: Int?
    let targetKilogramsTextSnapshot: String?
    var headCountText: String
    var actualKilogramsText: String
}

struct TMRFeedingCorrectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var runs: [TMRFeedingRunRecord]
    @Query private var allocations: [TMRFeedingAllocationRecord]
    @Query private var batches: [TMRBatchRecord]
    @Query private var movements: [TMRBatchMovementRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let runID: UUID
    private let commandService = FarmCommandService()

    @State private var occurredAt = Date.now
    @State private var meal: TMRMealPeriod = .morning
    @State private var rows: [TMRFeedingCorrectionPenInput] = []
    @State private var reason = ""
    @State private var note = ""
    @State private var didLoad = false
    @State private var errorMessage: String?

    private var originalRun: TMRFeedingRunRecord? {
        runs.first { $0.id == runID && $0.farmID == farm.id && $0.deletedAt == nil }
    }

    private var batch: TMRBatchRecord? {
        guard let batchID = originalRun?.batchID else { return nil }
        return batches.first { $0.id == batchID && $0.farmID == farm.id && $0.deletedAt == nil }
    }

    private var actualTotal: Decimal {
        rows.reduce(0) { $0 + (tmrDecimal($1.actualKilogramsText) ?? 0) }
    }

    var body: some View {
        Form {
            if let originalRun, let batch {
                Section("原投喂运行") {
                    LabeledContent("TMR 批次", value: originalRun.batchCodeSnapshot)
                    LabeledContent("配方快照", value: "\(originalRun.formulaNameSnapshot) v\(originalRun.formulaRevision)")
                    LabeledContent("批次当前余额") {
                        Text("\(batchBalance(batch.id).stableText) kg")
                    }
                    Text("这是一次多舍原子事实；保存修正时会先冲回整次原记录，再以本表全部圈舍重新入账。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("发生时间与顿次") {
                    DatePicker("投喂时间", selection: $occurredAt)
                    Picker("顿次", selection: $meal) {
                        ForEach(TMRMealPeriod.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("逐舍实际量") {
                    ForEach($rows) { $row in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(row.penName).font(.headline)
                            HStack {
                                Text("羊数快照")
                                Spacer()
                                TextField("只", text: $row.headCountText)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                Text("只")
                            }
                            HStack {
                                Text("实际投喂")
                                Spacer()
                                TextField("kg", text: $row.actualKilogramsText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                Text("kg")
                            }
                        }
                    }
                    LabeledContent("修正后合计") {
                        Text("\(actualTotal.stableText) kg")
                    }
                }
                Section("修正说明") {
                    TextField("必填修正原因", text: $reason, axis: .vertical).lineLimit(2...4)
                    TextField("投喂备注", text: $note, axis: .vertical).lineLimit(2...4)
                }
            } else {
                ContentUnavailableView("投喂记录已更新", systemImage: "arrow.clockwise", description: Text("请关闭后刷新事件历史。"))
            }
        }
        .navigationTitle("修正 TMR 投喂")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .onAppear(perform: loadIfNeeded)
        .recordErrorAlert($errorMessage)
    }

    private func loadIfNeeded() {
        guard !didLoad, let run = originalRun else { return }
        didLoad = true
        occurredAt = run.occurredAt
        meal = run.meal
        note = run.note
        rows = allocations.filter {
            $0.farmID == farm.id && $0.runID == run.id && $0.deletedAt == nil
        }.sorted {
            if $0.penNameSnapshot != $1.penNameSnapshot {
                return $0.penNameSnapshot.localizedStandardCompare($1.penNameSnapshot) == .orderedAscending
            }
            return $0.id.uuidString < $1.id.uuidString
        }.map {
            TMRFeedingCorrectionPenInput(
                id: $0.id,
                penID: $0.penID,
                penName: $0.penNameSnapshot,
                planID: $0.planID,
                planRevision: $0.planRevision,
                targetKilogramsTextSnapshot: $0.targetKilogramsTextSnapshot,
                headCountText: String($0.actualHeadCountSnapshot),
                actualKilogramsText: $0.actualKilogramsText
            )
        }
    }

    private func batchBalance(_ batchID: UUID) -> Decimal {
        TMRCalculator.batchBalance(movements: movements.filter {
            $0.farmID == farm.id && $0.batchID == batchID && $0.deletedAt == nil
        })
    }

    private func save() {
        guard let originalRun, let batch else {
            errorMessage = "原投喂记录或批次已更新，请刷新后重试。"
            return
        }
        let replacementAllocations = rows.compactMap { row -> TMRFeedingAllocationDraft? in
            guard let headCount = Int(row.headCountText), headCount > 0,
                  let actual = tmrDecimal(row.actualKilogramsText), actual > 0 else { return nil }
            return TMRFeedingAllocationDraft(
                penID: row.penID,
                planID: row.planID,
                planRevision: row.planRevision,
                actualHeadCountSnapshot: headCount,
                actualKilogramsText: actual.stableText,
                targetKilogramsTextSnapshot: row.targetKilogramsTextSnapshot
            )
        }
        guard replacementAllocations.count == rows.count, !rows.isEmpty else {
            errorMessage = "请为每个圈舍填写大于 0 的羊数和实际投喂量。"
            return
        }
        do {
            try commandService.correctTMRFeedingRun(
                TMRFeedingCorrectionDraft(
                    originalRunID: originalRun.id,
                    batchID: batch.id,
                    expectedBatchRevision: batch.revision,
                    occurredAt: occurredAt,
                    meal: meal,
                    allocations: replacementAllocations,
                    reason: reason,
                    note: note
                ),
                in: tmrFarmContext(account: account, farm: farm),
                context: modelContext
            )
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct TMRMonitoringView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FeedRecipeRecord.name) private var recipes: [FeedRecipeRecord]
    @Query(sort: \TMRFeedingPlanRecord.effectiveStartDate, order: .reverse) private var plans: [TMRFeedingPlanRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]

    let account: AccountProfile
    let farm: FarmRecord
    private let initialPlanID: UUID?
    private let initialPenID: UUID?
    private let commandService = FarmCommandService()

    @State private var selectedDate: Date
    @State private var formulaID: UUID?
    @State private var planID: UUID?
    @State private var penID: UUID?
    @State private var snapshot: TMRMonitoringSnapshot?
    @State private var isLoading = true
    @State private var refreshRevision = 0
    @State private var isEditingRule = false
    @State private var acknowledgementRow: TMRMonitoringRow?
    @State private var errorMessage: String?

    init(
        account: AccountProfile,
        farm: FarmRecord,
        initialDate: Date = .now,
        initialPlanID: UUID? = nil,
        initialPenID: UUID? = nil
    ) {
        self.account = account
        self.farm = farm
        self.initialPlanID = initialPlanID
        self.initialPenID = initialPenID
        _selectedDate = State(initialValue: initialDate)
        _planID = State(initialValue: initialPlanID)
        _penID = State(initialValue: initialPenID)
    }

    private var taskID: String {
        "\(selectedDate.timeIntervalSince1970):\(formulaID?.uuidString ?? "all"):\(planID?.uuidString ?? "all"):\(penID?.uuidString ?? "all"):\(refreshRevision)"
    }

    var body: some View {
        List {
            Section("筛选") {
                DatePicker("日期", selection: $selectedDate, displayedComponents: .date)
                Picker("配方", selection: $formulaID) {
                    Text("全部配方").tag(UUID?.none)
                    ForEach(formulaOptions, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                Picker("计划", selection: $planID) {
                    Text("全部计划").tag(UUID?.none)
                    ForEach(planOptions, id: \.id) { Text("\($0.formulaNameSnapshot) · v\($0.revision)").tag(UUID?.some($0.id)) }
                }
                Picker("圈舍", selection: $penID) {
                    Text("全部圈舍").tag(UUID?.none)
                    ForEach(penOptions, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }

            if isLoading {
                Section { ProgressView("正在汇总设定量与实际投喂") }
            } else if let snapshot {
                if !snapshot.monitoringConfigured {
                    Section("监控提醒") {
                        Text("当前可以查看差值，但牧场尚未确认偏差阈值和截止时间，因此不会自动生成少喂、漏喂提醒。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Button("确认并启用 TMR 监控", systemImage: "bell.badge") { isEditingRule = true }
                    }
                }
                if snapshot.rows.isEmpty {
                    ContentUnavailableView(
                        "没有匹配记录",
                        systemImage: "chart.bar.doc.horizontal",
                        description: Text("所选日期没有有效计划，也没有计划外 TMR 投喂。")
                    )
                } else {
                    ForEach(groupedRows, id: \.key) { group in
                        Section(group.key) {
                            ForEach(group.value, id: \.id) { row in
                                monitoringRow(row)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if row.planID != nil && !row.isCompleted {
                                            Button("完成") { complete(row) }.tint(.blue)
                                        }
                                        if row.isCompleted, row.completionID != nil {
                                            Button("重开") { reopen(row) }.tint(.orange)
                                        }
                                        if [.notFed, .low, .high].contains(row.status) && !row.isAcknowledged {
                                            Button("确认偏差") { acknowledgementRow = row }.tint(.purple)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("TMR 监控")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("TMR 监控设置", systemImage: "gearshape") { isEditingRule = true }
            }
        }
        .task(id: taskID) { await load() }
        .sheet(isPresented: $isEditingRule) {
            NavigationStack {
                TMRMonitoringRuleEditorView(account: account, farm: farm) {
                    isEditingRule = false
                    refreshRevision &+= 1
                }
            }
        }
        .sheet(item: $acknowledgementRow) { row in
            NavigationStack {
                TMRDeviationAcknowledgementView(account: account, farm: farm, row: row) {
                    acknowledgementRow = nil
                    refreshRevision &+= 1
                }
            }
        }
        .recordErrorAlert($errorMessage)
    }

    private var formulaOptions: [FeedRecipeRecord] {
        recipes.filter { $0.farmID == farm.id && $0.deletedAt == nil }
    }

    private var planOptions: [TMRFeedingPlanRecord] {
        plans.filter { $0.farmID == farm.id && $0.deletedAt == nil && (formulaID == nil || $0.formulaID == formulaID) }
    }

    private var penOptions: [PenRecord] {
        pens.filter { $0.farmID == farm.id && $0.deletedAt == nil }
    }

    private var groupedRows: [(key: String, value: [TMRMonitoringRow])] {
        let values = snapshot?.rows ?? []
        let dictionary = Dictionary(grouping: values) { "\($0.penName) · \($0.formulaName)" }
        return dictionary.keys.sorted().map { ($0, dictionary[$0] ?? []) }
    }

    @ViewBuilder
    private func monitoringRow(_ row: TMRMonitoringRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(row.meal.displayName)).font(.headline)
                Spacer()
                Label(LocalizedStringKey(row.status.displayName), systemImage: statusSymbol(row.status))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(row.status))
            }
            HStack {
                metric("设定", row.targetKilograms.map { "\($0.stableText) kg" } ?? "—")
                Spacer()
                metric("实际累计", "\(row.actualKilograms.stableText) kg")
                Spacer()
                metric("差值", row.differenceKilograms.map { "\($0.stableText) kg" } ?? "—")
            }
            if let percent = row.differencePercent {
                Text("偏差 \(percent.stableText)% · 截止 \(row.cutoffAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !row.batchCodes.isEmpty {
                Text("批次：\(row.batchCodes.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if row.isAcknowledged {
                Label("当前偏差已确认", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
        }
        .padding(.vertical, 3)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title)).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospacedDigit())
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            snapshot = try await TMRMonitoringReadActor(container: modelContext.container).load(
                farmID: farm.id,
                localDay: selectedDate,
                filter: TMRMonitoringFilter(formulaID: formulaID, planID: planID, penID: penID)
            )
            try Task.checkCancellation()
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func complete(_ row: TMRMonitoringRow) {
        guard let planID = row.planID, let planRevision = row.planRevision else { return }
        do {
            try commandService.completeTMRMeal(
                TMRMealCompletionDraft(
                    planID: planID,
                    expectedPlanRevision: planRevision,
                    penID: row.penID,
                    localDay: row.localDay,
                    meal: row.meal,
                    note: "在 TMR 监控中手工完成"
                ),
                in: tmrFarmContext(account: account, farm: farm),
                context: modelContext
            )
            refreshRevision &+= 1
        } catch { errorMessage = error.localizedDescription }
    }

    private func reopen(_ row: TMRMonitoringRow) {
        guard let completionID = row.completionID else { return }
        do {
            try commandService.reopenTMRMeal(
                TMRMealReopenDraft(completionID: completionID, reason: "继续追加本顿投料"),
                in: tmrFarmContext(account: account, farm: farm),
                context: modelContext
            )
            refreshRevision &+= 1
        } catch { errorMessage = error.localizedDescription }
    }

    private func statusColor(_ status: TMRDeviationStatus) -> Color {
        switch status {
        case .normal: .green
        case .inProgress: .blue
        case .unplanned: .orange
        case .notFed, .low, .high: .red
        }
    }

    private func statusSymbol(_ status: TMRDeviationStatus) -> String {
        switch status {
        case .normal: "checkmark.circle.fill"
        case .inProgress: "clock.fill"
        case .notFed: "xmark.circle.fill"
        case .low: "arrow.down.circle.fill"
        case .high: "arrow.up.circle.fill"
        case .unplanned: "exclamationmark.triangle.fill"
        }
    }
}

private struct TMRDeviationAcknowledgementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    let row: TMRMonitoringRow
    let onSaved: () -> Void
    private let commandService = FarmCommandService()
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("当前偏差") {
                LabeledContent("圈舍") { Text(verbatim: row.penName) }
                LabeledContent("顿次") { Text(LocalizedStringKey(row.meal.displayName)) }
                LabeledContent("状态") { Text(LocalizedStringKey(row.status.displayName)) }
                LabeledContent("目标") {
                    if let targetKilograms = row.targetKilograms {
                        Text("\(targetKilograms.stableText) kg")
                    } else {
                        Text("—")
                    }
                }
                LabeledContent("实际") {
                    Text("\(row.actualKilograms.stableText) kg")
                }
            }
            Section("确认说明") {
                TextField("必填备注", text: $note, axis: .vertical).lineLimit(3...6)
                Text("确认只绑定当前目标、有效投喂记录和完成状态；数据变化后仍会生成新的偏差。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("确认 TMR 偏差")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("确认", action: save) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        guard let planID = row.planID, let planRevision = row.planRevision else { return }
        do {
            try commandService.acknowledgeTMRDeviation(
                TMRDeviationAcknowledgementDraft(
                    planID: planID,
                    planRevision: planRevision,
                    penID: row.penID,
                    localDay: row.localDay,
                    meal: row.meal,
                    fingerprint: row.fingerprint,
                    note: note
                ),
                in: tmrFarmContext(account: account, farm: farm),
                context: modelContext
            )
            onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct TMRMonitoringRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var rules: [TMRMonitoringRuleRecord]
    let account: AccountProfile
    let farm: FarmRecord
    let onSaved: (() -> Void)?
    private let commandService = FarmCommandService()

    @State private var ruleID = UUID()
    @State private var expectedRevision = 0
    @State private var tolerancePercent = "5"
    @State private var morningTime = Date.now
    @State private var noonTime = Date.now
    @State private var eveningTime = Date.now
    @State private var allDayTime = Date.now
    @State private var monitoringEnabled = false
    @State private var didLoad = false
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, onSaved: (() -> Void)? = nil) {
        self.account = account
        self.farm = farm
        self.onSaved = onSaved
    }

    var body: some View {
        Form {
            Section("偏差阈值") {
                HStack {
                    Text("默认允许偏差")
                    Spacer()
                    TextField("%", text: $tolerancePercent).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    Text("%")
                }
                Text("每个投喂计划可以保存自己的阈值快照。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("顿次截止时间") {
                DatePicker("早顿", selection: $morningTime, displayedComponents: .hourAndMinute)
                DatePicker("中顿", selection: $noonTime, displayedComponents: .hourAndMinute)
                DatePicker("晚顿", selection: $eveningTime, displayedComponents: .hourAndMinute)
                DatePicker("全天汇总", selection: $allDayTime, displayedComponents: .hourAndMinute)
            }
            Section("启用确认") {
                Toggle("启用 TMR 偏差提醒", isOn: $monitoringEnabled)
                Text("未启用时仍可在监控页查看目标、实际和差值，但不会自动生成未投喂、偏低或偏高提醒。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("TMR 监控设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .onAppear(perform: loadIfNeeded)
        .recordErrorAlert($errorMessage)
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        func date(_ minute: Int) -> Date {
            Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
        }
        if let rule = rules.first(where: { $0.farmID == farm.id && $0.deletedAt == nil }) {
            ruleID = rule.id
            expectedRevision = rule.revision
            tolerancePercent = rule.tolerancePercentText
            morningTime = date(rule.morningCutoffMinute)
            noonTime = date(rule.noonCutoffMinute)
            eveningTime = date(rule.eveningCutoffMinute)
            allDayTime = date(rule.allDayCutoffMinute)
            monitoringEnabled = rule.monitoringEnabledAt != nil
        } else {
            morningTime = date(540)
            noonTime = date(840)
            eveningTime = date(1_200)
            allDayTime = date(1_320)
        }
    }

    private func minute(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func save() {
        do {
            try commandService.saveTMRMonitoringRule(
                TMRMonitoringRuleDraft(
                    id: ruleID,
                    expectedRevision: expectedRevision,
                    tolerancePercentText: tolerancePercent,
                    morningCutoffMinute: minute(morningTime),
                    noonCutoffMinute: minute(noonTime),
                    eveningCutoffMinute: minute(eveningTime),
                    allDayCutoffMinute: minute(allDayTime),
                    confirmsMonitoring: monitoringEnabled
                ),
                in: tmrFarmContext(account: account, farm: farm),
                context: modelContext
            )
            onSaved?()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
