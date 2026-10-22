import SwiftData
import SwiftUI
import UIKit
import CoreText

enum SheepSharePosterPhotoLayout: String, CaseIterable, Sendable {
    case landscape
    case portrait

    var sectionTitle: String {
        switch self {
        case .landscape: "横图照片"
        case .portrait: "竖图照片"
        }
    }

    var shortTitle: String {
        switch self {
        case .landscape: "横图"
        case .portrait: "竖图"
        }
    }
}

enum SheepSharePosterTheme: String, CaseIterable, Sendable {
    case dark
    case light

    var title: String {
        switch self {
        case .dark: "深色"
        case .light: "浅色"
        }
    }
}

enum SheepSharePosterStyle: String, CaseIterable, Identifiable, Sendable {
    case magazine
    case breeding
    case minimal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .magazine: "杂志封面"
        case .breeding: "种羊展示卡"
        case .minimal: "极简摄影"
        }
    }

    var subtitle: String {
        switch self {
        case .magazine: "大幅照片、醒目耳号与牧场落款"
        case .breeding: "展示照片、繁殖指标与三代系谱"
        case .minimal: "只展示照片、耳号与基础身份信息"
        }
    }
}

enum SheepSharePosterTemplate: String, CaseIterable, Identifiable, Sendable {
    case landscapeDark
    case landscapeLight
    case portraitDark
    case portraitLight

    /// Every exported poster is the same 9:16 portrait canvas. `photoLayout`
    /// describes how a landscape or portrait source photo is composed inside it.
    static let posterAspectRatio: CGFloat = 9.0 / 16.0
    static let logicalSize = CGSize(width: 360, height: 640)

    var id: String { rawValue }

    var photoLayout: SheepSharePosterPhotoLayout {
        switch self {
        case .landscapeDark, .landscapeLight: .landscape
        case .portraitDark, .portraitLight: .portrait
        }
    }

    var theme: SheepSharePosterTheme {
        switch self {
        case .landscapeDark, .portraitDark: .dark
        case .landscapeLight, .portraitLight: .light
        }
    }

    var displayName: String {
        "\(photoLayout.shortTitle) · \(theme.title)"
    }

    var canvasAspectRatio: CGFloat { Self.posterAspectRatio }
    var canvasSize: CGSize { Self.logicalSize }

    static func templates(for layout: SheepSharePosterPhotoLayout) -> [Self] {
        allCases.filter { $0.photoLayout == layout }
    }

    static func recommended(for image: UIImage?) -> Self {
        guard let image else { return .landscapeLight }
        let displayedSize: CGSize
        if let cgImage = image.cgImage {
            let sourceSize = CGSize(
                width: CGFloat(cgImage.width) / image.scale,
                height: CGFloat(cgImage.height) / image.scale
            )
            switch image.imageOrientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                displayedSize = CGSize(width: sourceSize.height, height: sourceSize.width)
            default:
                displayedSize = sourceSize
            }
        } else if let ciImage = image.ciImage {
            let sourceSize = ciImage.extent.size
            switch image.imageOrientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                displayedSize = CGSize(width: sourceSize.height, height: sourceSize.width)
            default:
                displayedSize = sourceSize
            }
        } else {
            // UIKit already reports a display-oriented size when the raw
            // backing image is unavailable, so do not rotate it a second time.
            displayedSize = image.size
        }
        return displayedSize.width >= displayedSize.height ? .landscapeLight : .portraitLight
    }
}

struct SheepSharePosterRelative: Sendable, Equatable {
    let earTag: String
    let breed: String?
}

struct SheepSharePosterPedigree: Sendable, Equatable {
    let maternalGranddam: SheepSharePosterRelative?
    let maternalGrandsire: SheepSharePosterRelative?
    let paternalGranddam: SheepSharePosterRelative?
    let paternalGrandsire: SheepSharePosterRelative?
    let dam: SheepSharePosterRelative?
    let sire: SheepSharePosterRelative?

    init(
        profile: PedigreeProfileSnapshot?,
        breedsBySheepID: [UUID: String] = [:]
    ) {
        maternalGranddam = Self.relative(profile?.maternalGranddam, breedsBySheepID: breedsBySheepID)
        maternalGrandsire = Self.relative(profile?.maternalGrandsire, breedsBySheepID: breedsBySheepID)
        paternalGranddam = Self.relative(profile?.paternalGranddam, breedsBySheepID: breedsBySheepID)
        paternalGrandsire = Self.relative(profile?.paternalGrandsire, breedsBySheepID: breedsBySheepID)
        dam = Self.relative(profile?.dam, breedsBySheepID: breedsBySheepID)
        if let sire = profile?.sire {
            self.sire = Self.relative(sire, breedsBySheepID: breedsBySheepID)
        } else if let donor = profile?.donor {
            self.sire = SheepSharePosterRelative(
                earTag: donor.name,
                breed: donor.breed.isEmpty ? nil : donor.breed
            )
        } else {
            sire = nil
        }
    }

    init(
        maternalGranddam: SheepSharePosterRelative? = nil,
        maternalGrandsire: SheepSharePosterRelative? = nil,
        paternalGranddam: SheepSharePosterRelative? = nil,
        paternalGrandsire: SheepSharePosterRelative? = nil,
        dam: SheepSharePosterRelative? = nil,
        sire: SheepSharePosterRelative? = nil
    ) {
        self.maternalGranddam = maternalGranddam
        self.maternalGrandsire = maternalGrandsire
        self.paternalGranddam = paternalGranddam
        self.paternalGrandsire = paternalGrandsire
        self.dam = dam
        self.sire = sire
    }

    private static func relative(
        _ value: PedigreeRelatedSheep?,
        breedsBySheepID: [UUID: String]
    ) -> SheepSharePosterRelative? {
        value.map {
            let breed = breedsBySheepID[$0.id]
            return SheepSharePosterRelative(
                earTag: $0.earTag,
                breed: breed?.isEmpty == false ? breed : nil
            )
        }
    }
}

struct SheepSharePosterLambing: Sendable, Equatable {
    let occurredAt: Date
}

struct SheepSharePosterMetrics: Sendable, Equatable {
    let currentParity: Int?
    let recentIntervalDays: Int?
    let lastLambingAt: Date?
    let postpartumDays: Int?

    static func make(
        sex: SheepSex,
        currentParity: Int?,
        lambings: [SheepSharePosterLambing],
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Self {
        guard sex == .ewe else {
            return Self(
                currentParity: nil,
                recentIntervalDays: nil,
                lastLambingAt: nil,
                postpartumDays: nil
            )
        }

        let ordered = lambings
            .filter { $0.occurredAt <= referenceDate }
            .sorted { $0.occurredAt < $1.occurredAt }
        let last = ordered.last?.occurredAt
        let previous = ordered.dropLast().last?.occurredAt
        let interval = previous.flatMap { previous in
            last.map { Self.days(from: previous, to: $0, calendar: calendar) }
        }
        let postpartum = last.map {
            max(0, Self.days(from: $0, to: referenceDate, calendar: calendar))
        }
        return Self(
            currentParity: currentParity,
            recentIntervalDays: interval,
            lastLambingAt: last,
            postpartumDays: postpartum
        )
    }

    private static func days(from start: Date, to end: Date, calendar: Calendar) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: start),
            to: calendar.startOfDay(for: end)
        ).day ?? 0
    }

    var parityText: String {
        guard let currentParity else { return "—" }
        return currentParity == 0 ? "尚未产羔" : "第 \(currentParity) 胎"
    }

    var intervalText: String {
        recentIntervalDays.map { "\($0) 天" } ?? "—"
    }

    var lastLambingText: String {
        lastLambingAt.map { Self.dottedDate($0) } ?? "—"
    }

    var postpartumText: String {
        postpartumDays.map { "\($0) 天" } ?? "—"
    }

    private static func dottedDate(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return "—" }
        return String(format: "%04d.%02d.%02d", year, month, day)
    }
}

struct SheepSharePosterSnapshot: Sendable, Equatable {
    let farmName: String
    var farmLatinName: String? = nil
    let subject: SheepDetailSubjectSnapshot
    let penName: String?
    let photoReference: SheepPhotoReference?
    let pedigree: SheepSharePosterPedigree
    let metrics: SheepSharePosterMetrics
    let generatedAt: Date

    var roleTitle: String {
        let purpose = subject.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        if !purpose.isEmpty, purpose != "未分类" { return purpose }
        switch subject.sex {
        case .ewe: return "母羊"
        case .ram: return "公羊"
        case .unknown: return "羊只"
        }
    }

    var identityLine: String {
        [subject.breed, subject.sex.displayName, subject.status.displayName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct SheepSharePosterCardField: Equatable {
    let id: String
    let title: String
    let value: String
}

extension SheepSharePosterSnapshot {
    var breedingCardSummary: String {
        switch subject.sex {
        case .ewe: "母羊展示卡 · 胎次、胎间距、产后天数"
        case .ram: "公羊展示卡 · 月龄、出生日期、当前羊舍"
        case .unknown: "通用展示卡 · 月龄、出生日期、当前羊舍"
        }
    }

    var posterCardFields: [SheepSharePosterCardField] {
        if subject.sex == .ewe {
            return [
                .init(id: "metric.0", title: "当前胎次", value: metrics.parityText),
                .init(id: "metric.1", title: "最近胎间距", value: metrics.intervalText),
                .init(id: "metric.2", title: "当前产后天数", value: metrics.postpartumText)
            ]
        }
        let calendar = Calendar.current
        let birth = subject.birthAt.flatMap { $0 <= generatedAt ? $0 : nil }
        let age = birth.flatMap {
            calendar.dateComponents([.month], from: calendar.startOfDay(for: $0),
                                    to: calendar.startOfDay(for: generatedAt)).month
        }
        let birthText = birth.map { date in
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d.%02d.%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        } ?? String(localized: "未填写")
        let currentPen = penName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            .init(id: "identity.age", title: "月龄",
                  value: age.map { String(localized: "\($0) 月龄") } ?? String(localized: "未填写")),
            .init(id: "identity.birth", title: "出生日期", value: birthText),
            .init(id: "identity.pen", title: "当前羊舍",
                  value: currentPen.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "未分配"))
        ]
    }
}

actor SheepSharePosterSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(
        farmID: UUID,
        farmName: String,
        sheepID: UUID,
        referenceDate: Date = .now
    ) throws -> SheepSharePosterSnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil
        })).first else {
            throw SheepDetailSnapshotError.sheepNotFound
        }
        let cloudState = try context.fetch(FetchDescriptor<ESheepCloudFarmState>(predicate: #Predicate {
            $0.farmID == farmID
        })).first
        let generation = cloudState?.farmGeneration ?? -1
        let identity = try context.fetch(FetchDescriptor<ESheepCloudFarmIdentityState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation
        })).first
        let subject = SheepDetailSubjectSnapshot(record: record)
        let penName: String?
        if let penID = subject.currentPenID {
            penName = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
                $0.id == penID && $0.farmID == farmID && $0.deletedAt == nil
            })).first?.name
        } else {
            penName = nil
        }
        let photoReference = try SheepAvatarSelectionStore.reference(
            sheepID: sheepID,
            farmID: farmID,
            context: context
        )
        let pedigree = try PedigreeAnalysis.screenSnapshot(
            sheepID: sheepID,
            farmID: farmID,
            context: context
        ).profile
        let pedigreeBreeds = try Self.loadPedigreeBreeds(
            profile: pedigree,
            farmID: farmID,
            context: context
        )
        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.eweID == sheepID && $0.deletedAt == nil
        }))
        let lambings = reproduction.compactMap { value -> SheepSharePosterLambing? in
            guard value.kind == .lambing else { return nil }
            return SheepSharePosterLambing(occurredAt: value.occurredAt)
        }
        let currentParity = subject.sex == .ewe
            ? LambingEntrySemantics.currentParity(
                eweID: sheepID,
                farmID: farmID,
                before: referenceDate.addingTimeInterval(0.001),
                records: reproduction
            )
            : nil
        try Task.checkCancellation()
        return SheepSharePosterSnapshot(
            farmName: identity?.name ?? farmName,
            farmLatinName: identity?.latinName,
            subject: subject,
            penName: penName,
            photoReference: photoReference,
            pedigree: SheepSharePosterPedigree(
                profile: pedigree,
                breedsBySheepID: pedigreeBreeds
            ),
            metrics: SheepSharePosterMetrics.make(
                sex: subject.sex,
                currentParity: currentParity,
                lambings: lambings,
                referenceDate: referenceDate
            ),
            generatedAt: referenceDate
        )
    }

    private static func loadPedigreeBreeds(
        profile: PedigreeProfileSnapshot?,
        farmID: UUID,
        context: ModelContext
    ) throws -> [UUID: String] {
        let relatives = [
            profile?.maternalGranddam,
            profile?.maternalGrandsire,
            profile?.paternalGranddam,
            profile?.paternalGrandsire,
            profile?.dam,
            profile?.sire
        ].compactMap { $0 }
        var result: [UUID: String] = [:]
        for relative in relatives where result[relative.id] == nil {
            let relativeID = relative.id
            if let record = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                $0.id == relativeID && $0.farmID == farmID && $0.deletedAt == nil
            })).first {
                result[relativeID] = record.breed
            }
        }
        return result
    }
}

enum SheepDetailShareDestination: String, Identifiable {
    case poster

    var id: String { rawValue }
}

struct SheepSharePosterSelectionView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let farmID: UUID
    let farmName: String
    let sheepID: UUID

    @State private var loadState: LoadState = .loading
    @State private var selectedStyle: SheepSharePosterStyle = .magazine
    @State private var selectedTemplate: SheepSharePosterTemplate = .landscapeLight
    @State private var previewPayload: SheepSharePosterPreviewPayload?
    @State private var isRendering = false
    @State private var errorMessage: String?
    @State private var isCustomizing = false
    @State private var customizations: [SheepSharePosterStyle: SheepSharePosterCustomization] = [:]

    private var currentCustomization: Binding<SheepSharePosterCustomization> {
        Binding(get: { customizations[selectedStyle] ?? .init() },
                set: { customizations[selectedStyle] = $0 })
    }

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView("正在准备海报")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("无法准备海报", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(LocalizedStringKey(message))
                } actions: {
                    Button("重新读取") { Task { await load() } }
                }
            case .loaded(let snapshot, let image):
                selectionContent(snapshot: snapshot, image: image)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        primaryAction(snapshot: snapshot, image: image)
                    }
            }
        }
        .background(AppTheme.pageBackground)
        .navigationTitle("选择海报模板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
        .task(id: sheepID) { await load() }
        .sheet(item: $previewPayload) { payload in
            NavigationStack {
                SheepSharePosterPreviewView(payload: payload)
            }
        }
        .sheet(isPresented: $isCustomizing) {
            if case .loaded(let snapshot, let image) = loadState {
                SheepSharePosterEditor(snapshot: snapshot, image: image, style: $selectedStyle,
                                       template: $selectedTemplate, customization: currentCustomization)
            }
        }
        .alert("海报", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("完成", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(errorMessage ?? ""))
        }
    }

    private func selectionContent(
        snapshot: SheepSharePosterSnapshot,
        image: UIImage?
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("海报风格", selection: $selectedStyle) {
                    ForEach(SheepSharePosterStyle.allCases) { style in
                        Text(LocalizedStringKey(style.title)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("sheepPoster.style")

                SheepSharePosterThumbnail(snapshot: snapshot, image: image, template: selectedTemplate, style: selectedStyle,
                                          customization: currentCustomization.wrappedValue)
                    .frame(maxWidth: 300)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("sheepPoster.thumbnail")
                    .clipShape(.rect(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("海报预览")

                Button("自定义排版与我的模板", systemImage: "slider.horizontal.3") { isCustomizing = true }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("sheepPoster.customize")

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(SheepSharePosterTemplate.allCases) { template in
                        posterTile(template: template)
                    }
                }

                Text(LocalizedStringKey(selectedStyle.subtitle))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if selectedStyle == .breeding {
                    Text(LocalizedStringKey(snapshot.breedingCardSummary))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if image == nil {
                    Label("当前头像照片不可用，海报将使用无照片版式。", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
    }

    private func posterTile(
        template: SheepSharePosterTemplate
    ) -> some View {
        let isSelected = selectedTemplate == template
        let palette = SheepSharePosterPalette(theme: template.theme, style: selectedStyle)
        return Button {
            selectedTemplate = template
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(palette.background)
                    .frame(width: 24, height: 32)
                    .overlay {
                        Image(systemName: template.photoLayout == .landscape ? "rectangle" : "rectangle.portrait")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.accent)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                    }
                Text(LocalizedStringKey(template.displayName))
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.brand)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(isSelected ? AppTheme.brand.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? AppTheme.brand : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 0.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(template.displayName)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityIdentifier("sheepPoster.template.\(template.rawValue)")
    }

    private func primaryAction(
        snapshot: SheepSharePosterSnapshot,
        image: UIImage?
    ) -> some View {
        Button {
            preparePreview(snapshot: snapshot, image: image)
        } label: {
            HStack(spacing: 8) {
                if isRendering { ProgressView().tint(.white) }
                Text(isRendering ? LocalizedStringKey("正在生成") : LocalizedStringKey("预览并分享"))
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(AppTheme.brand, in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(isRendering)
        .accessibilityIdentifier("sheepPoster.previewAndShare")
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    @MainActor
    private func load() async {
        loadState = .loading
        do {
            let snapshot = try await SheepSharePosterSnapshotActor(
                container: modelContext.container
            ).load(
                farmID: farmID,
                farmName: farmName,
                sheepID: sheepID
            )
            try Task.checkCancellation()
            let image: UIImage?
            if let photoReference = snapshot.photoReference,
               let data = try? await collaboration.loadPhotoData(assetID: photoReference.id) {
                image = UIImage(data: data)
            } else {
                image = nil
            }
            try Task.checkCancellation()
            selectedTemplate = SheepSharePosterTemplate.recommended(for: image)
            loadState = .loaded(snapshot, image)
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func preparePreview(
        snapshot: SheepSharePosterSnapshot,
        image: UIImage?
    ) {
        guard !isRendering else { return }
        isRendering = true
        defer { isRendering = false }
        guard let rendered = SheepSharePosterRenderer.render(
            snapshot: snapshot,
            image: image,
            template: selectedTemplate,
            style: selectedStyle,
            customization: currentCustomization.wrappedValue
        ) else {
            errorMessage = "海报生成失败，请稍后重试。"
            return
        }
        previewPayload = SheepSharePosterPreviewPayload(
            image: rendered,
            template: selectedTemplate,
            style: selectedStyle,
            earTag: snapshot.subject.earTag
        )
    }

    private enum LoadState {
        case loading
        case loaded(SheepSharePosterSnapshot, UIImage?)
        case failed(String)
    }
}

private struct SheepSharePosterThumbnail: View {
    let snapshot: SheepSharePosterSnapshot
    let image: UIImage?
    let template: SheepSharePosterTemplate
    var style: SheepSharePosterStyle = .magazine
    var customization = SheepSharePosterCustomization()

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / SheepSharePosterTemplate.logicalSize.width
            SheepSharePosterView(snapshot: snapshot, image: image, template: template, style: style, customization: customization)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .aspectRatio(SheepSharePosterTemplate.posterAspectRatio, contentMode: .fit)
        .clipped()
    }
}

@MainActor
enum SheepSharePosterRenderer {
    static func render(
        snapshot: SheepSharePosterSnapshot,
        image: UIImage?,
        template: SheepSharePosterTemplate,
        style: SheepSharePosterStyle = .magazine,
        customization: SheepSharePosterCustomization = .init()
    ) -> UIImage? {
        let renderer = ImageRenderer(
            content: SheepSharePosterView(
                snapshot: snapshot,
                image: image,
                template: template,
                style: style,
                customization: customization
            )
        )
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(SheepSharePosterTemplate.logicalSize)
        return renderer.uiImage
    }
}

struct SheepSharePosterPreviewPayload: Identifiable {
    let id = UUID()
    let image: UIImage
    let template: SheepSharePosterTemplate
    let style: SheepSharePosterStyle
    let earTag: String
}

private struct SheepSharePosterPreviewView: View {
    @Environment(\.dismiss) private var dismiss

    let payload: SheepSharePosterPreviewPayload
    @State private var activityItem: SheepSharePosterActivityItem?
    #if DEBUG
    @State private var exportEvidence = DevelopmentPosterExportEvidence()
    #endif

    var body: some View {
        ScrollView {
            Image(uiImage: payload.image)
                .resizable()
                .scaledToFit()
                .accessibilityIdentifier("sheepPoster.previewImage")
                #if DEBUG
                .accessibilityValue(exportEvidence.value(preview: payload.image))
                #endif
                .clipShape(.rect(cornerRadius: 18))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 7)
                .padding(20)
        }
        .background(AppTheme.pageBackground)
        .navigationTitle(LocalizedStringKey(payload.style.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("分享", systemImage: "square.and.arrow.up") {
                    activityItem = SheepSharePosterActivityItem(image: payload.image)
                }
                .accessibilityIdentifier("sheepPoster.systemShare")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("分享海报", systemImage: "square.and.arrow.up") {
                activityItem = SheepSharePosterActivityItem(image: payload.image)
            }
            .font(.headline)
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.brandSoft)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
            .accessibilityIdentifier("sheepPoster.sharePoster")
        }
        .sheet(item: $activityItem) { item in
            #if DEBUG
            SheepSharePosterActivityView(image: item.image, evidence: exportEvidence)
            #else
            SheepSharePosterActivityView(image: item.image)
            #endif
        }
    }
}

private struct SheepSharePosterActivityItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct SheepSharePosterActivityView: UIViewControllerRepresentable {
    let image: UIImage
    #if DEBUG
    var evidence: DevelopmentPosterExportEvidence?
    #endif

    func makeUIViewController(context: Context) -> UIActivityViewController {
        #if DEBUG
        if DevelopmentPosterAcceptance.directory != nil, let evidence {
            return UIActivityViewController(activityItems: [image],
                applicationActivities: [DevelopmentPosterSaveActivity(evidence: evidence)])
        }
        #endif
        return UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

struct SheepSharePosterView: View {
    let snapshot: SheepSharePosterSnapshot
    let image: UIImage?
    let template: SheepSharePosterTemplate
    var style: SheepSharePosterStyle = .magazine
    var customization = SheepSharePosterCustomization()
    var selectedID: String?
    var interactionScale: CGFloat = 1
    var onSelect: ((String) -> Void)?
    var onMove: ((String, CGSize, Bool) -> Void)?

    private var palette: SheepSharePosterPalette {
        .init(theme: template.theme, style: style)
    }
    private var elements: [SheepPosterElement] {
        customization.elements(from: SheepSharePosterLayout.elements(snapshot: snapshot, style: style, template: template))
    }
    private var sourcePhoto: UIImage? {
        customization.photoData.flatMap(UIImage.init(data:)) ?? image
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            (customization.background?.color ?? palette.background)
                .zIndex(-Double.greatestFiniteMagnitude)
            ForEach(elements.filter { !$0.isHidden }) { element in
                layer(element)
                    .frame(width: element.width, height: element.height,
                           alignment: element.centered ? .center : .leading)
                    .opacity(element.opacity)
                    .overlay {
                        if selectedID == element.id {
                            Rectangle().strokeBorder(.blue, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    .contentShape(.rect)
                    .rotationEffect(.degrees(element.rotation))
                    .onTapGesture { onSelect?(element.id) }
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .onChanged { value in
                                onSelect?(element.id)
                                onMove?(element.id, CGSize(width: value.translation.width / interactionScale,
                                                         height: value.translation.height / interactionScale), false)
                            }
                            .onEnded { value in
                                onMove?(element.id, CGSize(width: value.translation.width / interactionScale,
                                                         height: value.translation.height / interactionScale), true)
                            },
                        including: onMove == nil ? .none : .all
                    )
                    .allowsHitTesting(onSelect != nil && (element.kind != .shade || selectedID == element.id))
                    .position(x: element.x + element.width / 2, y: element.y + element.height / 2)
                    .zIndex(element.order)
            }
        }
        .frame(width: 360, height: 640)
        .clipped()
        .environment(\.colorScheme, template.theme == .dark ? .dark : .light)
        .environment(\.dynamicTypeSize, .medium)
    }

    @ViewBuilder private func layer(_ element: SheepPosterElement) -> some View {
        switch element.kind {
        case .text:
            Text(element.text)
                .font(element.font.font(size: element.fontSize, text: element.text))
                .tracking(element.tracking)
                .foregroundStyle(element.color.color)
                .multilineTextAlignment(element.centered ? .center : .leading)
                .lineLimit(element.text.contains("\n") ? 3 : 1)
                .minimumScaleFactor(0.2)
        case .photo, .photoBackdrop:
            if let photo = element.imageData.flatMap(UIImage.init(data:)) ?? sourcePhoto {
                Image(uiImage: photo).resizable().scaledToFill()
                    .frame(width: element.width, height: element.height)
                    .scaleEffect(element.photoZoom)
                    .offset(x: element.photoX, y: element.photoY)
                    .clipped()
                    .blur(radius: element.kind == .photoBackdrop ? 10 : 0, opaque: true)
                    .mask {
                        if element.kind == .photo && style != .breeding {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.13),
                                .init(color: .black, location: 0.90),
                                .init(color: .clear, location: 1)
                            ], startPoint: .top, endPoint: .bottom)
                        } else if element.kind == .photo {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.08),
                                .init(color: .black, location: 1)
                            ], startPoint: .top, endPoint: .bottom)
                        } else { Rectangle() }
                    }
            } else {
                ZStack {
                    LinearGradient(colors: [palette.panel, palette.background],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    if element.kind == .photo {
                        Text("照片待补充").font(.system(size: 11)).tracking(3)
                            .foregroundStyle(palette.foreground.opacity(0.5))
                    }
                }
            }
        case .logo, .image:
            if let customImage = element.imageData.flatMap(UIImage.init(data:)) {
                Image(uiImage: customImage).resizable().scaledToFit()
            } else if element.kind == .logo {
                Image("PosterAppIcon").resizable().scaledToFit()
            } else {
                Rectangle().fill(.gray.opacity(0.15))
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        case .rule:
            Rectangle().fill(element.color.color)
        case .brush:
            SheepSharePosterBrushStroke().fill(element.color.color)
        case .mountains:
            Canvas { context, size in
                for index in 0..<3 {
                    var ridge = Path()
                    ridge.move(to: CGPoint(x: 0, y: size.height))
                    ridge.addLine(to: CGPoint(x: 0, y: size.height * 0.6))
                    for step in 1...9 {
                        let wave = sin(Double(step) * 1.7 + Double(index) * 2.1)
                        let point = CGPoint(x: size.width * Double(step) / 9,
                                            y: size.height * (0.35 + Double(index) * 0.16 + wave * 0.14))
                        ridge.addQuadCurve(to: point, control: CGPoint(x: point.x - size.width / 18,
                                                                      y: point.y - size.height * 0.14))
                    }
                    ridge.addLine(to: CGPoint(x: size.width, y: size.height))
                    ridge.closeSubpath()
                    context.fill(ridge, with: .color(element.color.color.opacity(0.10 + Double(index) * 0.06)))
                }
            }
        case .shade:
            LinearGradient(stops: [
                .init(color: element.color.color.opacity(0.63), location: 0),
                .init(color: element.color.color.opacity(0.30), location: 0.28),
                .init(color: .clear, location: 0.55),
                .init(color: element.color.color.opacity(0.1), location: 0.73),
                .init(color: element.color.color.opacity(0.7), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

enum SheepSharePosterTypography {
    // Register bundled OFL fonts once, before both on-screen and exported text
    // are laid out. This also works offline and on a clean installation.
    private static let registration: Void = {
        for name in ["Knewave-Regular", "MaShanZheng-Regular", "NotoSerifSC",
                     "ZCOOLXiaoWei-Regular", "ZhiMangXing-Regular"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    static func register() { _ = registration }

    static func brush(size: CGFloat) -> Font {
        _ = registration
        return .custom("Knewave-Regular", fixedSize: size)
    }

    static func handwriting(size: CGFloat) -> Font {
        _ = registration
        return .custom("MaShanZheng-Regular", fixedSize: size)
    }
}

private struct SheepSharePosterBrushStroke: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points: [CGPoint] = [
            .init(x: 0, y: 0.48), .init(x: 0.06, y: 0.18),
            .init(x: 0.33, y: 0.28), .init(x: 0.76, y: 0.06),
            .init(x: 1, y: 0.2), .init(x: 0.87, y: 0.43),
            .init(x: 0.98, y: 0.50), .init(x: 0.67, y: 0.64),
            .init(x: 0.88, y: 0.72), .init(x: 0.39, y: 0.81),
            .init(x: 0.03, y: 1), .init(x: 0.1, y: 0.67)
        ]
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
        path.closeSubpath()
        return path
    }
}

private struct SheepSharePosterPalette {
    let theme: SheepSharePosterTheme
    var style: SheepSharePosterStyle = .magazine

    var background: Color {
        if style == .breeding {
            return theme == .light
                ? Color(red: 0.95, green: 0.98, blue: 1)
                : Color(red: 0.025, green: 0.08, blue: 0.15)
        }
        return Color(red: 0.055, green: 0.065, blue: 0.06)
    }

    var panel: Color {
        if style == .breeding {
            return theme == .light
                ? Color(red: 0.73, green: 0.87, blue: 0.98)
                : Color(red: 0.08, green: 0.19, blue: 0.31)
        }
        return Color(red: 0.19, green: 0.22, blue: 0.18)
    }

    var foreground: Color {
        style == .breeding && theme == .light
            ? Color(red: 0.025, green: 0.12, blue: 0.22)
            : Color(red: 0.98, green: 0.97, blue: 0.91)
    }

    var accent: Color { Color(red: 0.98, green: 0.82, blue: 0.18) }
    var line: Color { foreground.opacity(0.25) }
}

#Preview("羊只海报四模板") {
    ScrollView(.horizontal) {
        HStack(spacing: 16) {
            ForEach(SheepSharePosterTemplate.allCases) { template in
                SheepSharePosterView(
                    snapshot: .preview,
                    image: nil,
                    template: template
                )
                .scaleEffect(0.72, anchor: .topLeading)
                .frame(width: 259, height: 461)
                .clipped()
            }
        }
        .padding()
    }
}

private extension SheepSharePosterSnapshot {
    static var preview: Self {
        let referenceDate = Date(timeIntervalSince1970: 1_785_628_800)
        return Self(
            farmName: "青禾牧场",
            subject: SheepDetailSubjectSnapshot(
                id: UUID(),
                earTag: "E0387",
                breed: "杜湖杂交",
                purpose: "繁殖母羊",
                sex: .ewe,
                status: .active,
                initialPenID: nil,
                currentPenID: nil,
                birthAt: nil,
                enteredAt: referenceDate,
                removedAt: nil
            ),
            penName: nil,
            photoReference: nil,
            pedigree: SheepSharePosterPedigree(
                maternalGrandsire: .init(earTag: "R0061", breed: "湖羊"),
                dam: .init(earTag: "E0216", breed: "湖羊"),
                sire: .init(earTag: "R0182", breed: "杜泊")
            ),
            metrics: SheepSharePosterMetrics(
                currentParity: 3,
                recentIntervalDays: 342,
                lastLambingAt: referenceDate.addingTimeInterval(-225 * 86_400),
                postpartumDays: 225
            ),
            generatedAt: referenceDate
        )
    }
}
