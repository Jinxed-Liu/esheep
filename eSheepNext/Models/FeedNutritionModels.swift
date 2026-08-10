import Foundation

/// The source kind is persisted on the farm ingredient, while the system
/// template itself remains immutable.  A farm ingredient always owns its
/// nutrient snapshot after it is added from the system library.
enum FeedIngredientKind: String, Codable, CaseIterable, Sendable, Hashable {
    case system
    case custom
    case mixture
    case legacy

    var displayName: String {
        switch self {
        case .system: "系统原料"
        case .custom: "自定义原料"
        case .mixture: "混合料"
        case .legacy: "历史原料"
        }
    }
}

enum FeedRecipeStage: String, Codable, CaseIterable, Sendable, Hashable {
    case lactatingLamb = "哺乳羔羊"
    case weanedLamb = "断奶羔羊"
    case growing = "育成羊"
    case replacementEwe = "后备母羊"
    case breedingEwe = "繁殖母羊"
    case ram = "种公羊"
    case fattening = "育肥羊"
    case custom = "自定义"

    var displayName: String { rawValue }
}

enum FeedPackagingKind: String, Codable, CaseIterable, Sendable, Hashable {
    case bulk
    case bag
    case bale
    case other

    var displayName: String {
        switch self {
        case .bulk: "散装"
        case .bag: "袋装"
        case .bale: "包/捆装"
        case .other: "其他包装"
        }
    }
}

/// How the physical stock count was obtained.  A bulk ingredient can be
/// counted as an unresolved physical check without inventing kilograms.
enum FeedStockCountMethod: String, Codable, CaseIterable, Sendable, Hashable {
    case weighed = "实称"
    case packagedCount = "按包装数量"
    case volumeEstimate = "按体积密度估算"
    case notMeasured = "暂未称量"

    var displayName: String { rawValue }
    var isConfirmed: Bool { self == .weighed || self == .packagedCount }
    var isEstimated: Bool { self == .volumeEstimate }
}

/// A trough observation is a physical fact, independent from a feed delivery.
/// Estimated methods remain usable, but analysis must label them as estimated.
enum FeedTroughMeasurementMethod: String, Codable, CaseIterable, Sendable, Hashable {
    case weighed = "实称"
    case volumeEstimate = "按体积密度估算"
    case visualEstimate = "目测估算"

    var displayName: String { rawValue }
    var isEstimated: Bool { self != .weighed }
}

/// Optional composition captured at the trough. Quantities describe the
/// observed remainder before any `discardedKilogramsText` is cleared out.
struct FeedTroughCompositionComponent: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let ingredientID: UUID?
    let ingredientBatchID: UUID?
    let ingredientNameSnapshot: String
    let kilogramsText: String
    let nutrientSnapshotJSON: String
    let dryMatterTextSnapshot: String?

    init(
        id: UUID = UUID(),
        ingredientID: UUID? = nil,
        ingredientBatchID: UUID? = nil,
        ingredientNameSnapshot: String,
        kilogramsText: String,
        nutrientSnapshotJSON: String = "{}",
        dryMatterTextSnapshot: String? = nil
    ) {
        self.id = id
        self.ingredientID = ingredientID
        self.ingredientBatchID = ingredientBatchID
        self.ingredientNameSnapshot = ingredientNameSnapshot
        self.kilogramsText = kilogramsText
        self.nutrientSnapshotJSON = nutrientSnapshotJSON
        self.dryMatterTextSnapshot = dryMatterTextSnapshot
    }

    var kilograms: Decimal { Decimal.stable(kilogramsText) ?? 0 }
}

enum FeedTroughCompositionCodec {
    static func encode(_ components: [FeedTroughCompositionComponent]) -> String {
        guard let data = try? JSONEncoder.feed.encode(components) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String?) -> [FeedTroughCompositionComponent] {
        guard let json,
              let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode([FeedTroughCompositionComponent].self, from: data) else {
            return []
        }
        return value
    }
}

enum FeedExcludedSheepCodec {
    static func encode(_ identifiers: [UUID]) -> String {
        let ordered = Array(Set(identifiers)).sorted { $0.uuidString < $1.uuidString }
        guard let data = try? JSONEncoder.feed.encode(ordered) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String?) -> [UUID] {
        guard let json,
              let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode([UUID].self, from: data) else {
            return []
        }
        return value
    }
}

enum FeedNutrientKey: String, Codable, CaseIterable, Sendable, Hashable {
    case dryMatter
    case crudeProtein
    case crudeFat
    case crudeFiber
    case ndf
    case adf
    case ash
    case lignin
    case peNDF
    case starch
    case sugar
    case tdn
    case de
    case me
    case rdp
    case rup
    case ndip
    case adip
    case solubleProtein
    case mpe
    case mpn
    case digestibleProtein
    case rumenNitrogenBalance
    case lysine
    case methionine

    var displayName: String {
        switch self {
        case .dryMatter: "干物质 DM"
        case .crudeProtein: "粗蛋白 CP"
        case .crudeFat: "粗脂肪"
        case .crudeFiber: "粗纤维"
        case .ndf: "NDF"
        case .adf: "ADF"
        case .ash: "灰分"
        case .lignin: "木质素"
        case .peNDF: "peNDF"
        case .starch: "淀粉"
        case .sugar: "糖"
        case .tdn: "TDN"
        case .de: "DE"
        case .me: "ME"
        case .rdp: "可降解蛋白 RDP"
        case .rup: "非降解蛋白 RUP"
        case .ndip: "NDIP"
        case .adip: "ADIP"
        case .solubleProtein: "可溶性蛋白"
        case .mpe: "代谢蛋白能量来源 MPE"
        case .mpn: "代谢蛋白氮来源 MPN"
        case .digestibleProtein: "可消化蛋白"
        case .rumenNitrogenBalance: "瘤胃氮平衡"
        case .lysine: "赖氨酸"
        case .methionine: "蛋氨酸"
        }
    }

    var unit: String {
        switch self {
        case .de, .me: "Mcal/kg DM"
        case .dryMatter, .crudeProtein, .crudeFat, .crudeFiber, .ndf, .adf,
             .ash, .lignin, .peNDF, .starch, .sugar, .tdn, .rdp, .rup,
             .ndip, .adip, .solubleProtein, .mpe, .mpn, .digestibleProtein,
             .rumenNitrogenBalance, .lysine, .methionine: "% DM"
        }
    }

    var isEnergy: Bool { self == .de || self == .me }
}

/// This is intentionally compatible with Plus' JSON shape.  DE and ME are
/// stored in Mcal/kg DM; presentation and total-energy calculations convert
/// them to MJ explicitly.
struct FeedNutrients: Codable, Hashable, Sendable {
    static let megajoulesPerMegacalorie = 4.184

    var dryMatter: Double?
    var crudeProtein: Double?
    var crudeFat: Double?
    var crudeFiber: Double?
    var ndf: Double?
    var adf: Double?
    var ash: Double?
    var lignin: Double?
    var peNDF: Double?
    var starch: Double?
    var sugar: Double?
    var tdn: Double?
    var de: Double?
    var me: Double?
    var rdp: Double?
    var rup: Double?
    var ndip: Double?
    var adip: Double?
    var solubleProtein: Double?
    var mpe: Double?
    var mpn: Double?
    var digestibleProtein: Double?
    var rumenNitrogenBalance: Double?
    var lysine: Double?
    var methionine: Double?
    var extra: [String: Double]?

    init(
        dryMatter: Double? = nil,
        crudeProtein: Double? = nil,
        crudeFat: Double? = nil,
        crudeFiber: Double? = nil,
        ndf: Double? = nil,
        adf: Double? = nil,
        ash: Double? = nil,
        lignin: Double? = nil,
        peNDF: Double? = nil,
        starch: Double? = nil,
        sugar: Double? = nil,
        tdn: Double? = nil,
        de: Double? = nil,
        me: Double? = nil,
        rdp: Double? = nil,
        rup: Double? = nil,
        ndip: Double? = nil,
        adip: Double? = nil,
        solubleProtein: Double? = nil,
        mpe: Double? = nil,
        mpn: Double? = nil,
        digestibleProtein: Double? = nil,
        rumenNitrogenBalance: Double? = nil,
        lysine: Double? = nil,
        methionine: Double? = nil,
        extra: [String: Double]? = nil
    ) {
        self.dryMatter = dryMatter
        self.crudeProtein = crudeProtein
        self.crudeFat = crudeFat
        self.crudeFiber = crudeFiber
        self.ndf = ndf
        self.adf = adf
        self.ash = ash
        self.lignin = lignin
        self.peNDF = peNDF
        self.starch = starch
        self.sugar = sugar
        self.tdn = tdn
        self.de = de
        self.me = me
        self.rdp = rdp
        self.rup = rup
        self.ndip = ndip
        self.adip = adip
        self.solubleProtein = solubleProtein
        self.mpe = mpe
        self.mpn = mpn
        self.digestibleProtein = digestibleProtein
        self.rumenNitrogenBalance = rumenNitrogenBalance
        self.lysine = lysine
        self.methionine = methionine
        self.extra = extra
    }

    static let empty = FeedNutrients()

    var deMJPerKgDM: Double? { de.map { $0 * Self.megajoulesPerMegacalorie } }
    var meMJPerKgDM: Double? { me.map { $0 * Self.megajoulesPerMegacalorie } }

    /// Preserve Plus' deterministic fill rules, but callers can use the
    /// returned inferred key set to label those values as “推算”.
    var fillingMissingEnergyValues: FeedNutrients {
        fillingMissingEnergyValuesWithKeys.nutrients
    }

    var fillingMissingEnergyValuesWithKeys: (nutrients: FeedNutrients, keys: Set<FeedNutrientKey>) {
        var result = self
        var inferred = Set<FeedNutrientKey>()
        let tdnToDE = 0.04409
        let meToDERatio = 0.82

        if Self.isMissing(result.tdn), let de {
            result.tdn = de / tdnToDE
            inferred.insert(.tdn)
        }
        if Self.isMissing(result.de), let tdn = Self.positive(result.tdn) {
            result.de = tdn * tdnToDE
            inferred.insert(.de)
        }
        if Self.isMissing(result.me), let de = Self.positive(result.de) {
            result.me = de * meToDERatio
            inferred.insert(.me)
        }
        if Self.isMissing(result.de), let me = Self.positive(result.me) {
            result.de = me / meToDERatio
            inferred.insert(.de)
        }
        if Self.isMissing(result.tdn), let de = Self.positive(result.de) {
            result.tdn = de / tdnToDE
            inferred.insert(.tdn)
        }
        return (result, inferred)
    }

    func value(for key: FeedNutrientKey) -> Double? {
        switch key {
        case .dryMatter: dryMatter
        case .crudeProtein: crudeProtein
        case .crudeFat: crudeFat
        case .crudeFiber: crudeFiber
        case .ndf: ndf
        case .adf: adf
        case .ash: ash
        case .lignin: lignin
        case .peNDF: peNDF
        case .starch: starch
        case .sugar: sugar
        case .tdn: tdn
        case .de: de
        case .me: me
        case .rdp: rdp
        case .rup: rup
        case .ndip: ndip
        case .adip: adip
        case .solubleProtein: solubleProtein
        case .mpe: mpe
        case .mpn: mpn
        case .digestibleProtein: digestibleProtein
        case .rumenNitrogenBalance: rumenNitrogenBalance
        case .lysine: lysine
        case .methionine: methionine
        }
    }

    func setting(_ value: Double?, for key: FeedNutrientKey) -> FeedNutrients {
        var result = self
        switch key {
        case .dryMatter: result.dryMatter = value
        case .crudeProtein: result.crudeProtein = value
        case .crudeFat: result.crudeFat = value
        case .crudeFiber: result.crudeFiber = value
        case .ndf: result.ndf = value
        case .adf: result.adf = value
        case .ash: result.ash = value
        case .lignin: result.lignin = value
        case .peNDF: result.peNDF = value
        case .starch: result.starch = value
        case .sugar: result.sugar = value
        case .tdn: result.tdn = value
        case .de: result.de = value
        case .me: result.me = value
        case .rdp: result.rdp = value
        case .rup: result.rup = value
        case .ndip: result.ndip = value
        case .adip: result.adip = value
        case .solubleProtein: result.solubleProtein = value
        case .mpe: result.mpe = value
        case .mpn: result.mpn = value
        case .digestibleProtein: result.digestibleProtein = value
        case .rumenNitrogenBalance: result.rumenNitrogenBalance = value
        case .lysine: result.lysine = value
        case .methionine: result.methionine = value
        }
        return result
    }

    static func weightedAverage(_ items: [(nutrients: FeedNutrients, ratio: Double)]) -> FeedNutrients {
        guard !items.isEmpty else { return .empty }
        func weighted(_ key: FeedNutrientKey) -> Double? {
            let values = items.compactMap { item in item.nutrients.value(for: key).map { $0 * item.ratio } }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        let base = FeedNutrients(
            dryMatter: weighted(.dryMatter), crudeProtein: weighted(.crudeProtein), crudeFat: weighted(.crudeFat),
            crudeFiber: weighted(.crudeFiber), ndf: weighted(.ndf), adf: weighted(.adf), ash: weighted(.ash),
            lignin: weighted(.lignin), peNDF: weighted(.peNDF), starch: weighted(.starch), sugar: weighted(.sugar),
            tdn: weighted(.tdn), de: weighted(.de), me: weighted(.me), rdp: weighted(.rdp), rup: weighted(.rup),
            ndip: weighted(.ndip), adip: weighted(.adip), solubleProtein: weighted(.solubleProtein), mpe: weighted(.mpe),
            mpn: weighted(.mpn), digestibleProtein: weighted(.digestibleProtein),
            rumenNitrogenBalance: weighted(.rumenNitrogenBalance), lysine: weighted(.lysine),
            methionine: weighted(.methionine), extra: nil
        )
        let extraKeys = Set(items.compactMap(\.nutrients.extra?.keys).flatMap { $0 })
        guard !extraKeys.isEmpty else { return base }
        var extra: [String: Double] = [:]
        for key in extraKeys {
            let values = items.compactMap { item in
                item.nutrients.extra?[key].map { value in value * item.ratio }
            }
            if !values.isEmpty { extra[key] = values.reduce(0, +) }
        }
        var result = base
        result.extra = extra.isEmpty ? nil : extra
        return result
    }

    private static func isMissing(_ value: Double?) -> Bool { value == nil || value ?? 0 <= 0.05 }
    private static func positive(_ value: Double?) -> Double? { guard let value, value > 0 else { return nil }; return value }
}

struct FeedIngredientTemplate: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let code: String
    let name: String
    let category: String
    let updatedAt: String
    let referencePrice: Double?
    let nutrients: FeedNutrients
}

/// A mixture stores the ingredient snapshots and the percentage used at the
/// time it was prepared.  It is deliberately independent from later catalog
/// edits so a recipe/history cannot drift when a source ingredient changes.
struct FeedMixtureComponent: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let ingredientID: UUID?
    let ingredientName: String
    let sharePercent: Double
    let nutrients: FeedNutrients
    let pricePerKilogram: Double?

    init(id: UUID = UUID(), ingredientID: UUID? = nil, ingredientName: String, sharePercent: Double, nutrients: FeedNutrients, pricePerKilogram: Double? = nil) {
        self.id = id
        self.ingredientID = ingredientID
        self.ingredientName = ingredientName
        self.sharePercent = sharePercent
        self.nutrients = nutrients
        self.pricePerKilogram = pricePerKilogram
    }
}

struct FeedMixtureResult: Hashable, Sendable {
    let components: [FeedMixtureComponent]
    let nutrients: FeedNutrients
    let pricePerKilogram: Double?
}

enum FeedMixtureCalculatorError: LocalizedError {
    case needsAtLeastTwoIngredients
    case invalidShare
    case sharesMustEqualOneHundred

    var errorDescription: String? {
        switch self {
        case .needsAtLeastTwoIngredients: "混合料至少需要两种原料。"
        case .invalidShare: "混合比例必须是大于 0 的百分比。"
        case .sharesMustEqualOneHundred: "混合比例合计必须等于 100%。"
        }
    }
}

enum FeedMixtureCalculator {
    static func calculate(components: [FeedMixtureComponent]) throws -> FeedMixtureResult {
        guard components.count >= 2 else { throw FeedMixtureCalculatorError.needsAtLeastTwoIngredients }
        guard components.allSatisfy({ $0.sharePercent > 0 && $0.sharePercent.isFinite }) else {
            throw FeedMixtureCalculatorError.invalidShare
        }
        let totalShare = components.reduce(0) { $0 + $1.sharePercent }
        guard abs(totalShare - 100) < 0.0001 else {
            throw FeedMixtureCalculatorError.sharesMustEqualOneHundred
        }
        let weighted = FeedNutrients.weightedAverage(components.map {
            (nutrients: $0.nutrients, ratio: $0.sharePercent / 100)
        })
        let prices = components.compactMap { component in
            component.pricePerKilogram.map { price in price * component.sharePercent / 100 }
        }
        let price = prices.count == components.count ? prices.reduce(0, +) : nil
        return FeedMixtureResult(components: components, nutrients: weighted, pricePerKilogram: price)
    }
}

enum FeedMixtureCodec {
    static func encode(_ components: [FeedMixtureComponent]) -> String {
        guard let data = try? JSONEncoder.feed.encode(components) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String?) -> [FeedMixtureComponent] {
        guard let json, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode([FeedMixtureComponent].self, from: data) else {
            return []
        }
        return value
    }
}

struct FeedNutrientCoverage: Codable, Hashable, Sendable {
    let coverage: Double
    let missingIngredientNames: [String]
    let inferred: Bool

    var isComplete: Bool { coverage >= 0.999999 }
}

struct FeedNutritionComponent: Hashable, Sendable {
    let ingredientID: UUID?
    let ingredientName: String
    let freshKilograms: Double
    let pricePerKilogram: Double?
    let nutrients: FeedNutrients

    init(ingredientID: UUID? = nil, ingredientName: String, freshKilograms: Double, pricePerKilogram: Double? = nil, nutrients: FeedNutrients) {
        self.ingredientID = ingredientID
        self.ingredientName = ingredientName
        self.freshKilograms = freshKilograms
        self.pricePerKilogram = pricePerKilogram
        self.nutrients = nutrients
    }
}

struct FeedRecipeNutritionSummary: Hashable, Sendable {
    let asFedKilograms: Double
    let dryMatterKilograms: Double?
    let cost: Double?
    let nutrients: FeedNutrients
    let coverage: [FeedNutrientKey: FeedNutrientCoverage]
    let extraCoverage: [String: FeedNutrientCoverage]

    var dryMatterPercent: Double? {
        guard let dryMatterKilograms, asFedKilograms > 0 else { return nil }
        return dryMatterKilograms / asFedKilograms * 100
    }

    var meMJ: Double? {
        guard let dryMatterKilograms, let me = nutrients.meMJPerKgDM,
              coverage[.me]?.isComplete == true else { return nil }
        return dryMatterKilograms * me
    }

    var crudeProteinKilograms: Double? {
        guard let dryMatterKilograms, let cp = nutrients.crudeProtein,
              coverage[.crudeProtein]?.isComplete == true else { return nil }
        return dryMatterKilograms * cp / 100
    }

    var ndfKilograms: Double? {
        guard let dryMatterKilograms, let ndf = nutrients.ndf,
              coverage[.ndf]?.isComplete == true else { return nil }
        return dryMatterKilograms * ndf / 100
    }

    var adfKilograms: Double? {
        guard let dryMatterKilograms, let adf = nutrients.adf,
              coverage[.adf]?.isComplete == true else { return nil }
        return dryMatterKilograms * adf / 100
    }

    func perHead(headCount: Int?) -> FeedRecipeNutritionSummary? {
        guard let headCount, headCount > 0 else { return nil }
        let divisor = Double(headCount)
        return FeedRecipeNutritionSummary(
            asFedKilograms: asFedKilograms / divisor,
            dryMatterKilograms: dryMatterKilograms.map { $0 / divisor },
            cost: cost.map { $0 / divisor },
            nutrients: nutrients,
            coverage: coverage,
            extraCoverage: extraCoverage
        )
    }

    static func calculate(components: [FeedNutritionComponent]) -> FeedRecipeNutritionSummary {
        let asFed = components.reduce(0) { $0 + $1.freshKilograms }
        let dmValues = components.compactMap { component -> (Double, FeedNutritionComponent)? in
            guard let dm = component.nutrients.dryMatter else { return nil }
            return (component.freshKilograms * dm / 100, component)
        }
        let dryMatter: Double? = dmValues.count == components.count ? dmValues.reduce(0) { $0 + $1.0 } : nil
        let costValues = components.compactMap { component in component.pricePerKilogram.map { component.freshKilograms * $0 } }
        let cost: Double? = costValues.count == components.count ? costValues.reduce(0, +) : nil
        let denominator = dmValues.reduce(0) { $0 + $1.0 }
        var weighted = FeedNutrients(dryMatter: asFed > 0 ? (dryMatter.map { $0 / asFed * 100 }) : nil)
        var coverage: [FeedNutrientKey: FeedNutrientCoverage] = [:]

        for key in FeedNutrientKey.allCases.dropFirst() {
            let filled = components.map { component in
                let fill = component.nutrients.fillingMissingEnergyValuesWithKeys
                return (component, fill.nutrients, fill.keys.contains(key))
            }
            let known = filled.enumerated().compactMap { index, item -> (contribution: Double, dryMatter: Double, name: String, inferred: Bool)? in
                guard let dm = item.0.nutrients.dryMatter,
                      let value = item.1.value(for: key) else { return nil }
                let componentDM = components[index].freshKilograms * dm / 100
                return (componentDM * value, componentDM, item.0.ingredientName, item.2)
            }
            let coveredDM = known.reduce(0) { $0 + $1.dryMatter }
            let ratio = denominator > 0 ? min(1, coveredDM / denominator) : 0
            let missing = components.filter { component in
                guard component.nutrients.dryMatter != nil else { return true }
                return component.nutrients.fillingMissingEnergyValuesWithKeys.nutrients.value(for: key) == nil
            }.map(\.ingredientName)
            let value: Double? = denominator > 0 && ratio >= 0.999999
                ? known.reduce(0) { $0 + $1.contribution } / denominator
                : nil
            weighted = weighted.setting(value, for: key)
            let inferred = known.contains { $0.inferred }
            coverage[key] = FeedNutrientCoverage(coverage: ratio, missingIngredientNames: missing, inferred: inferred)
        }

        let extraKeys = Set(components.compactMap(\.nutrients.extra?.keys).flatMap { $0 })
        var extra: [String: Double] = [:]
        var extraCoverage: [String: FeedNutrientCoverage] = [:]
        for key in extraKeys {
            let known = components.compactMap { component -> (contribution: Double, dryMatter: Double, name: String)? in
                guard let dm = component.nutrients.dryMatter,
                      let value = component.nutrients.extra?[key] else { return nil }
                let componentDM = component.freshKilograms * dm / 100
                return (componentDM * value, componentDM, component.ingredientName)
            }
            let coveredDM = known.reduce(0) { $0 + $1.dryMatter }
            let ratio = denominator > 0 ? min(1, coveredDM / denominator) : 0
            let missing = components.filter { $0.nutrients.dryMatter == nil || $0.nutrients.extra?[key] == nil }.map(\.ingredientName)
            if denominator > 0, ratio >= 0.999999 {
                extra[key] = known.reduce(0) { $0 + $1.contribution } / denominator
            }
            extraCoverage[key] = FeedNutrientCoverage(coverage: ratio, missingIngredientNames: missing, inferred: false)
        }
        weighted.extra = extra.isEmpty ? nil : extra

        return FeedRecipeNutritionSummary(
            asFedKilograms: asFed,
            dryMatterKilograms: dryMatter,
            cost: cost,
            nutrients: weighted,
            coverage: coverage,
            extraCoverage: extraCoverage
        )
    }
}

struct FeedMPAnalysis: Hashable, Sendable {
    let mpKilograms: Double?
    let estimated: Bool
    let blockedReason: String?

    static func calculate(summary: FeedRecipeNutritionSummary) -> FeedMPAnalysis {
        guard summary.coverage[.crudeProtein]?.isComplete == true else {
            return FeedMPAnalysis(mpKilograms: nil, estimated: false, blockedReason: "粗蛋白覆盖率不足")
        }
        let dryMatter = summary.dryMatterKilograms
        guard let dryMatter, let cp = summary.nutrients.crudeProtein else {
            return FeedMPAnalysis(mpKilograms: nil, estimated: false, blockedReason: "干物质或粗蛋白缺失")
        }
        if summary.coverage[.rdp]?.isComplete == true,
           summary.coverage[.rup]?.isComplete == true,
           let rdp = summary.nutrients.rdp,
           let rup = summary.nutrients.rup {
            let adip = summary.nutrients.adip ?? 0
            let mp = dryMatter * max(0, (rup + rdp * 0.8 - adip) / 100)
            return FeedMPAnalysis(mpKilograms: mp, estimated: false, blockedReason: nil)
        }
        // Plus-compatible fallback: when only CP is available, preserve the
        // split as an explicitly estimated model instead of presenting it as a
        // measured MP value.
        let estimatedMP = dryMatter * cp / 100 * 0.64
        return FeedMPAnalysis(mpKilograms: estimatedMP, estimated: true, blockedReason: nil)
    }
}

enum FeedTemplateLibraryError: LocalizedError {
    case resourceNotFound
    case invalidResource

    var errorDescription: String? {
        switch self {
        case .resourceNotFound: "系统原料库资源不存在。"
        case .invalidResource: "系统原料库资源无法解码。"
        }
    }
}

enum FeedTemplateLibrary {
    static func load() throws -> [FeedIngredientTemplate] {
        guard let url = Bundle.main.url(forResource: "FeedIngredientTemplates", withExtension: "json") else {
            throw FeedTemplateLibraryError.resourceNotFound
        }
        return try load(from: url)
    }

    static func load(from url: URL) throws -> [FeedIngredientTemplate] {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode([FeedIngredientTemplate].self, from: Data(contentsOf: url))
        } catch {
            throw FeedTemplateLibraryError.invalidResource
        }
    }
}

enum FeedNutritionCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func encode(_ nutrients: FeedNutrients) -> String {
        guard let data = try? encoder.encode(nutrients) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String?) -> FeedNutrients {
        guard let json, let data = json.data(using: .utf8) else {
            return .empty
        }
        var value = (try? JSONDecoder().decode(FeedNutrients.self, from: data)) ?? .empty
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return value
        }

        func number(_ keys: [String]) -> Double? {
            for key in keys {
                if let number = object[key] as? NSNumber { return number.doubleValue }
                if let text = object[key] as? String, let number = Double(text) { return number }
            }
            return nil
        }

        // A few early Plus exports used compact field names. Codable accepts
        // those payloads while silently leaving every optional property nil,
        // so normalize the aliases here before analysis instead of treating
        // real historical nutrients as zero or missing.
        if value.dryMatter == nil { value.dryMatter = number(["dm", "DM"]) }
        if value.crudeProtein == nil { value.crudeProtein = number(["cp", "CP"]) }
        if value.crudeFat == nil { value.crudeFat = number(["ee", "EE", "fat"]) }
        if value.crudeFiber == nil { value.crudeFiber = number(["cf", "CF", "fiber"]) }
        if value.ndf == nil { value.ndf = number(["NDF"]) }
        if value.adf == nil { value.adf = number(["ADF"]) }
        if value.ash == nil { value.ash = number(["Ash", "ASH"]) }
        if value.starch == nil { value.starch = number(["Starch"]) }
        if value.sugar == nil { value.sugar = number(["Sugar"]) }
        if value.tdn == nil { value.tdn = number(["TDN"]) }
        if value.de == nil { value.de = number(["DE"]) }
        if value.me == nil { value.me = number(["ME"]) }
        if value.rdp == nil { value.rdp = number(["RDP"]) }
        if value.rup == nil { value.rup = number(["RUP"]) }
        if value.ndip == nil { value.ndip = number(["NDIP"]) }
        if value.adip == nil { value.adip = number(["ADIP"]) }
        return value
    }
}

private extension JSONEncoder {
    static let feed: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
