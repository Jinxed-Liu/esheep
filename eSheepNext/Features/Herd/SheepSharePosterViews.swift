import SwiftData
import SwiftUI
import UIKit

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
            farmName: farmName,
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
    @State private var selectedTemplate: SheepSharePosterTemplate = .landscapeLight
    @State private var previewPayload: SheepSharePosterPreviewPayload?
    @State private var isRendering = false
    @State private var errorMessage: String?

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
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 6) {
                    Text("为")
                    Text(snapshot.subject.earTag)
                        .fontWeight(.semibold)
                        .foregroundStyle(AppTheme.brand)
                    Text("选择分享样式")
                }
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)

                templateSection(
                    title: SheepSharePosterPhotoLayout.landscape.sectionTitle,
                    templates: SheepSharePosterTemplate.templates(for: .landscape),
                    snapshot: snapshot,
                    image: image
                )
                templateSection(
                    title: SheepSharePosterPhotoLayout.portrait.sectionTitle,
                    templates: SheepSharePosterTemplate.templates(for: .portrait),
                    snapshot: snapshot,
                    image: image
                )

                HStack {
                    Text("分享内容")
                    Spacer()
                    Text("系谱与繁殖信息")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.body)
                .padding(.horizontal, 18)
                .frame(minHeight: 56)
                .background(.background, in: .rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                }

                if image == nil {
                    Label("当前头像照片不可用，海报会使用系统羊只图形。", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
    }

    private func templateSection(
        title: String,
        templates: [SheepSharePosterTemplate],
        snapshot: SheepSharePosterSnapshot,
        image: UIImage?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title))
                .font(.headline)
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(templates) { template in
                    posterTile(template: template, snapshot: snapshot, image: image)
                }
            }
        }
    }

    private func posterTile(
        template: SheepSharePosterTemplate,
        snapshot: SheepSharePosterSnapshot,
        image: UIImage?
    ) -> some View {
        let isSelected = selectedTemplate == template
        return Button {
            selectedTemplate = template
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    SheepSharePosterThumbnail(
                        snapshot: snapshot,
                        image: image,
                        template: template
                    )
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? AppTheme.brandSoft : Color.primary.opacity(0.10), lineWidth: isSelected ? 3 : 1)
                    }

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white, AppTheme.brandSoft)
                            .padding(7)
                    }
                }
                Text(LocalizedStringKey(template.displayName))
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AppTheme.brand : .primary)
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
            template: selectedTemplate
        ) else {
            errorMessage = "海报生成失败，请稍后重试。"
            return
        }
        previewPayload = SheepSharePosterPreviewPayload(
            image: rendered,
            template: selectedTemplate,
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

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / SheepSharePosterTemplate.logicalSize.width
            SheepSharePosterView(snapshot: snapshot, image: image, template: template)
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
        template: SheepSharePosterTemplate
    ) -> UIImage? {
        let renderer = ImageRenderer(
            content: SheepSharePosterView(
                snapshot: snapshot,
                image: image,
                template: template
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
    let earTag: String
}

private struct SheepSharePosterPreviewView: View {
    @Environment(\.dismiss) private var dismiss

    let payload: SheepSharePosterPreviewPayload
    @State private var activityItem: SheepSharePosterActivityItem?

    var body: some View {
        ScrollView {
            Image(uiImage: payload.image)
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 18))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 7)
                .padding(20)
        }
        .background(AppTheme.pageBackground)
        .navigationTitle(payload.template.displayName)
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
            SheepSharePosterActivityView(image: item.image)
        }
    }
}

private struct SheepSharePosterActivityItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct SheepSharePosterActivityView: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private struct SheepSharePosterView: View {
    let snapshot: SheepSharePosterSnapshot
    let image: UIImage?
    let template: SheepSharePosterTemplate

    var body: some View {
        Group {
            switch template.photoLayout {
            case .landscape:
                landscapePhotoPoster
            case .portrait:
                portraitPhotoPoster
            }
        }
        .frame(
            width: SheepSharePosterTemplate.logicalSize.width,
            height: SheepSharePosterTemplate.logicalSize.height
        )
        .background(palette.background)
        .clipped()
        .environment(\.colorScheme, template.theme == .dark ? .dark : .light)
    }

    private var landscapePhotoPoster: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                posterPhoto
                    .frame(
                        width: SheepSharePosterTemplate.logicalSize.width,
                        height: 260
                    )
                    .clipped()
                brandRegion
            }
            .frame(
                width: SheepSharePosterTemplate.logicalSize.width,
                height: 260,
                alignment: .topLeading
            )
            .clipped()
            VStack(alignment: .leading, spacing: 10) {
                landscapeIdentityHeader
                SheepSharePosterPedigreeView(
                    snapshot: snapshot,
                    palette: palette,
                    compact: true
                )
                metricStrip
                footer
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(palette.background)
        }
    }

    private var portraitPhotoPoster: some View {
        ZStack {
            posterPhoto
                .frame(
                    width: SheepSharePosterTemplate.logicalSize.width,
                    height: SheepSharePosterTemplate.logicalSize.height
                )
                .clipped()
            portraitPhotoWash
            brandRegion
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 10) {
                Spacer()
                    .frame(height: 64)
                portraitIdentityHeader
                Spacer(minLength: 18)
                SheepSharePosterPedigreeView(
                    snapshot: snapshot,
                    palette: palette,
                    compact: false
                )
                metricStrip
                footer
            }
            .padding(16)
        }
    }

    private var portraitPhotoWash: some View {
        LinearGradient(
            stops: template.theme == .dark
                ? [
                    .init(color: Color.black.opacity(0.10), location: 0),
                    .init(color: Color.black.opacity(0.04), location: 0.34),
                    .init(color: Color.black.opacity(0.28), location: 0.58),
                    .init(color: Color.black.opacity(0.68), location: 1)
                ]
                : [
                    .init(color: Color.white.opacity(0.12), location: 0),
                    .init(color: Color.white.opacity(0.02), location: 0.34),
                    .init(color: Color.white.opacity(0.30), location: 0.58),
                    .init(color: Color.white.opacity(0.78), location: 1)
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private var posterPhoto: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                palette.photoFallback
                Image(systemName: "sheep")
                    .font(.system(size: 76, weight: .medium))
                    .foregroundStyle(palette.accent.opacity(0.72))
            }
        }
    }

    private var brandRegion: some View {
        ZStack(alignment: .topLeading) {
            RadialGradient(
                stops: template.theme == .dark
                    ? [
                        .init(color: Color.black.opacity(0.72), location: 0),
                        .init(color: Color.black.opacity(0.42), location: 0.34),
                        .init(color: Color.black.opacity(0), location: 0.80)
                    ]
                    : [
                        .init(color: Color.white.opacity(0.96), location: 0),
                        .init(color: Color.white.opacity(0.66), location: 0.34),
                        .init(color: Color.white.opacity(0), location: 0.80)
                    ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 145
            )

            VStack(spacing: 1) {
                Image("PosterBrandMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(palette.logoForeground)
                    .frame(width: 38, height: 36)
                Text("eSheep+")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                Text(snapshot.farmName)
                    .font(.system(size: 8, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(width: 64)
            .padding(.leading, 14)
            .padding(.top, 12)
            .foregroundStyle(palette.logoForeground)
            .shadow(color: palette.logoShadow, radius: 1.5, y: 1)
        }
        .frame(width: 145, height: 120)
        .allowsHitTesting(false)
    }

    private var landscapeIdentityHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(snapshot.subject.earTag)
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(LocalizedStringKey(snapshot.roleTitle))
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(palette.accent, in: .capsule)
            }
            Text(snapshot.identityLine)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(palette.secondaryForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var portraitIdentityHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(snapshot.roleTitle))
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(1)
            Text(snapshot.subject.earTag)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(palette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text("品种  \(breedDisplayName)")
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Text([snapshot.subject.sex.displayName, snapshot.subject.status.displayName].joined(separator: " · "))
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(palette.identityRibbon)
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [palette.identityBackdrop, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var breedDisplayName: String {
        snapshot.subject.breed.isEmpty ? "未填写" : snapshot.subject.breed
    }

    private var metricStrip: some View {
        HStack(spacing: 0) {
            metric(symbol: "number", title: "当前胎次", value: snapshot.metrics.parityText)
            metricDivider
            metric(symbol: "calendar", title: "最近胎间距", value: snapshot.metrics.intervalText)
            metricDivider
            metric(symbol: "sheep", title: "上次产羔", value: snapshot.metrics.lastLambingText)
            metricDivider
            metric(symbol: "clock", title: "当前产后天数", value: snapshot.metrics.postpartumText)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 3)
        .background(template.photoLayout == .portrait ? palette.panel.opacity(0.90) : .clear)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.line.opacity(0.55))
                .frame(height: 0.7)
        }
    }

    private func metric(symbol: String, title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(palette.accent)
            Text(LocalizedStringKey(title))
                .font(.system(size: 6.5, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(palette.accent)
            Text(value)
                .font(.system(size: 10.2, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity)
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(palette.line)
            .frame(width: 0.7, height: 34)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Rectangle()
                .frame(width: 20, height: 0.7)
            Text(LocalizedStringKey(generatedDateText))
            Rectangle()
                .frame(width: 20, height: 0.7)
        }
        .frame(maxWidth: .infinity)
        .font(.system(size: 7, weight: .medium, design: .rounded))
        .foregroundStyle(palette.secondaryForeground)
    }

    private var generatedDateText: String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: snapshot.generatedAt
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return "" }
        return String(format: "%04d.%02d.%02d", year, month, day)
    }

    private var palette: SheepSharePosterPalette {
        SheepSharePosterPalette(theme: template.theme)
    }
}

struct SheepSharePosterPedigreeLayout: Sendable, Equatable {
    let height: CGFloat
    let grandNodeHeight: CGFloat = 34
    let parentNodeHeight: CGFloat = 42
    let subjectNodeHeight: CGFloat = 48
    let grandY: CGFloat
    let parentY: CGFloat
    let subjectY: CGFloat

    init(compact: Bool) {
        height = compact ? 160 : 164
        grandY = grandNodeHeight / 2
        parentY = compact ? 73 : 75
        subjectY = height - subjectNodeHeight / 2
    }

    var grandBottom: CGFloat { grandY + grandNodeHeight / 2 }
    var parentTop: CGFloat { parentY - parentNodeHeight / 2 }
    var parentBottom: CGFloat { parentY + parentNodeHeight / 2 }
    var subjectTop: CGFloat { subjectY - subjectNodeHeight / 2 }
    var subjectBottom: CGFloat { subjectY + subjectNodeHeight / 2 }
    var grandJunctionY: CGFloat { (grandBottom + parentTop) / 2 }
    var parentJunctionY: CGFloat { (parentBottom + subjectTop) / 2 }
}

private struct SheepSharePosterPedigreeView: View {
    let snapshot: SheepSharePosterSnapshot
    let palette: SheepSharePosterPalette
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("核心系谱")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(palette.sectionTitle)
            GeometryReader { proxy in
                let width = proxy.size.width
                Canvas { context, size in
                    let grandXs = [0.125, 0.375, 0.625, 0.875].map { size.width * $0 }
                    let parentXs = [size.width * 0.25, size.width * 0.75]
                    var path = Path()
                    for index in 0..<2 {
                        let left = grandXs[index * 2]
                        let right = grandXs[index * 2 + 1]
                        path.move(to: CGPoint(x: left, y: pedigreeLayout.grandBottom))
                        path.addLine(to: CGPoint(x: left, y: pedigreeLayout.grandJunctionY))
                        path.addLine(to: CGPoint(x: right, y: pedigreeLayout.grandJunctionY))
                        path.addLine(to: CGPoint(x: right, y: pedigreeLayout.grandBottom))
                        path.move(to: CGPoint(x: parentXs[index], y: pedigreeLayout.grandJunctionY))
                        path.addLine(to: CGPoint(x: parentXs[index], y: pedigreeLayout.parentTop))
                    }
                    path.move(to: CGPoint(x: parentXs[0], y: pedigreeLayout.parentBottom))
                    path.addLine(to: CGPoint(x: parentXs[0], y: pedigreeLayout.parentJunctionY))
                    path.addLine(to: CGPoint(x: parentXs[1], y: pedigreeLayout.parentJunctionY))
                    path.addLine(to: CGPoint(x: parentXs[1], y: pedigreeLayout.parentBottom))
                    path.move(to: CGPoint(x: size.width * 0.5, y: pedigreeLayout.parentJunctionY))
                    path.addLine(to: CGPoint(x: size.width * 0.5, y: pedigreeLayout.subjectTop))
                    context.stroke(path, with: .color(palette.line), lineWidth: 1)
                }
                Group {
                    node(label: "外祖母", relative: snapshot.pedigree.maternalGranddam, width: width * 0.20, height: pedigreeLayout.grandNodeHeight, strong: false)
                        .position(x: width * 0.125, y: pedigreeLayout.grandY)
                    node(label: "外祖父", relative: snapshot.pedigree.maternalGrandsire, width: width * 0.20, height: pedigreeLayout.grandNodeHeight, strong: false)
                        .position(x: width * 0.375, y: pedigreeLayout.grandY)
                    node(label: "祖母", relative: snapshot.pedigree.paternalGranddam, width: width * 0.20, height: pedigreeLayout.grandNodeHeight, strong: false)
                        .position(x: width * 0.625, y: pedigreeLayout.grandY)
                    node(label: "祖父", relative: snapshot.pedigree.paternalGrandsire, width: width * 0.20, height: pedigreeLayout.grandNodeHeight, strong: false)
                        .position(x: width * 0.875, y: pedigreeLayout.grandY)
                    node(label: "母本", relative: snapshot.pedigree.dam, width: width * 0.28, height: pedigreeLayout.parentNodeHeight, strong: true)
                        .position(x: width * 0.25, y: pedigreeLayout.parentY)
                    node(label: "父本", relative: snapshot.pedigree.sire, width: width * 0.28, height: pedigreeLayout.parentNodeHeight, strong: true)
                        .position(x: width * 0.75, y: pedigreeLayout.parentY)
                    node(
                        label: "本羊",
                        relative: SheepSharePosterRelative(
                            earTag: snapshot.subject.earTag,
                            breed: snapshot.subject.breed
                        ),
                        width: width * 0.43,
                        height: pedigreeLayout.subjectNodeHeight,
                        strong: true
                    )
                    .position(x: width * 0.5, y: pedigreeLayout.subjectY)
                }
            }
            .frame(height: pedigreeLayout.height)
            .clipped()
        }
        .padding(.horizontal, compact ? 0 : 12)
        .padding(.top, compact ? 2 : 10)
        .padding(.bottom, compact ? 4 : 10)
        .background {
            if compact {
                Color.clear
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(palette.panel.opacity(0.92))
            }
        }
    }

    private var pedigreeLayout: SheepSharePosterPedigreeLayout {
        SheepSharePosterPedigreeLayout(compact: compact)
    }

    private func node(
        label: String,
        relative: SheepSharePosterRelative?,
        width: CGFloat,
        height: CGFloat,
        strong: Bool
    ) -> some View {
        VStack(spacing: 1) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 6.4, weight: .medium))
                .foregroundStyle(palette.secondaryForeground)
            Text(relative.map(relativeTitle) ?? "未确认")
                .font(.system(size: strong ? 8.2 : 7.4, weight: strong ? .semibold : .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(width: width, height: height)
        .background(strong ? palette.nodeStrong : palette.node, in: .rect(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(relative == nil ? palette.line.opacity(0.65) : palette.accent.opacity(0.42), lineWidth: 0.8)
        }
    }

    private func relativeTitle(_ relative: SheepSharePosterRelative) -> String {
        [relative.earTag, relative.breed]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }
}

private struct SheepSharePosterPalette {
    let theme: SheepSharePosterTheme

    var background: Color {
        theme == .dark
            ? Color(red: 0.025, green: 0.075, blue: 0.15)
            : Color(red: 0.965, green: 0.98, blue: 1.0)
    }

    var panel: Color {
        theme == .dark
            ? Color(red: 0.035, green: 0.12, blue: 0.24)
            : Color.white
    }

    var foreground: Color {
        theme == .dark ? .white : Color(red: 0.08, green: 0.12, blue: 0.18)
    }

    var secondaryForeground: Color {
        foreground.opacity(theme == .dark ? 0.78 : 0.70)
    }

    var accent: Color { Color(red: 0.05, green: 0.38, blue: 0.88) }

    var sectionTitle: Color {
        theme == .dark ? .white : accent
    }

    var logoForeground: Color {
        theme == .dark ? .white : accent
    }

    var logoShadow: Color {
        theme == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.9)
    }

    var identityBackdrop: Color {
        theme == .dark ? Color.black.opacity(0.58) : Color.white.opacity(0.82)
    }

    var identityRibbon: Color {
        theme == .dark
            ? Color(red: 0.46, green: 0.34, blue: 0.16).opacity(0.72)
            : Color(red: 0.94, green: 0.82, blue: 0.62).opacity(0.72)
    }

    var line: Color {
        theme == .dark ? Color.white.opacity(0.45) : accent.opacity(0.36)
    }

    var node: Color {
        theme == .dark ? Color.white.opacity(0.055) : Color.gray.opacity(0.055)
    }

    var nodeStrong: Color {
        theme == .dark ? accent.opacity(0.075) : accent.opacity(0.035)
    }

    var photoFallback: Color {
        theme == .dark ? Color(red: 0.07, green: 0.13, blue: 0.20) : Color(red: 0.84, green: 0.92, blue: 0.99)
    }
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
