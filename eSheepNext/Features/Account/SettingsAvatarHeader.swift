import SwiftUI
import UIKit

/// The scroll-content button owns input. Its geometry never feeds back into
/// expansion; the header and renderer receive the same explicit animation value.
@MainActor
struct SettingsAvatarHeader: View, Animatable {
    let account: AccountProfile
    let farm: FarmRecord
    let motion: AccountAvatarMotionCoordinator
    nonisolated(unsafe) var expansion: CGFloat
    let onTap: () -> Void
    let onEdit: () -> Void

    @State private var metrics = SettingsAvatarWindowMetrics.empty

    nonisolated var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    var body: some View {
        let width = metrics.width > 0 ? metrics.width : max(100, motion.availableWidth)
        let expandedSide = settingsAvatarExpandedSide(width: width, height: motion.availableHeight)
        let status = metrics.statusBarHeight
        let progress = boundedSettingsAvatarProgress(expansion)
        let titleHeight = SettingsAvatarTypography.titleHeight
        let subtitleHeight = SettingsAvatarTypography.subtitleHeight
        let normalHeight = status + 131 + titleHeight + 4 + subtitleHeight
        let expandedHeight = expandedSide + 60 - 21
        let height = max(0, normalHeight + (expandedHeight - normalHeight) * progress - motion.contentOrigin.y)
        let layout = SettingsAvatarRenderLayout(
            width: width, expandedSide: expandedSide,
            statusBarHeight: status, windowOrigin: .zero,
            offset: motion.scrollOffset, titleProgress: motion.titleProgress,
            expansion: progress, animationsEnabled: motion.animationsEnabled
        )
        ZStack(alignment: .topLeading) {
            Button(action: onTap) {
                Color.clear
                    .frame(width: layout.photoFrame.width, height: layout.photoFrame.height)
                    .contentShape(.rect(cornerRadius: layout.cornerRadius))
            }
            .buttonStyle(.plain)
            .offset(
                x: layout.photoFrame.minX - motion.contentOrigin.x,
                y: layout.photoFrame.minY + motion.scrollOffset - motion.contentOrigin.y
            )
            .accessibilityLabel("头像")
            .accessibilityHint(Text(LocalizedStringKey(progress > 0.5 ? "点按查看头像" : "点按展开头像")))
            .accessibilityIdentifier("account-avatar-entry")
            .accessibilityHidden(motion.titleProgress > 0.99 && progress < 0.01)
            .allowsHitTesting(motion.titleProgress < 1 || progress > 0.01)
            .accessibilityAction(named: Text("更换头像"), onEdit)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(account.displayName + " · " + farm.name))
        .onGeometryChange(for: CGPoint.self) { geometry in
            geometry.frame(in: .global).origin
        } action: { origin in
            // Only the stable content origin is measured; expansion changes
            // height beneath this point and never supplies animation progress.
            motion.updateContentOrigin(CGPoint(
                x: origin.x, y: origin.y + motion.scrollOffset
            ))
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            motion.updateAvailableWidth(width)
        }
        .background {
            SettingsAvatarWindowProbe { value in
                let stable = SettingsAvatarWindowMetrics(
                    width: value.width, statusBarHeight: value.statusBarHeight,
                    windowOriginInView: .zero, supportsIsland: value.supportsIsland
                )
                if metrics != stable { metrics = stable }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The animation value is an explicit input. UIView geometry is queried only
/// on demand for gallery transitions, never read back as expansion progress.
@MainActor
struct SettingsAvatarOverlay: View, Animatable {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    let account: AccountProfile
    let farm: FarmRecord
    let motion: AccountAvatarMotionCoordinator
    nonisolated(unsafe) var expansion: CGFloat

    @State private var metrics = SettingsAvatarWindowMetrics.empty

    nonisolated var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = metrics.width > 0 ? metrics.width : max(100, geometry.size.width)
            let expandedSide = settingsAvatarExpandedSide(width: width, height: geometry.size.height)
            let layout = SettingsAvatarRenderLayout(
                width: width, expandedSide: expandedSide,
                statusBarHeight: metrics.statusBarHeight,
                windowOrigin: metrics.windowOriginInView,
                offset: motion.scrollOffset, titleProgress: motion.titleProgress,
                expansion: boundedSettingsAvatarProgress(expansion),
                animationsEnabled: motion.animationsEnabled
            )
            SettingsAvatarRenderer(
                image: motion.previewDigest == digest ? motion.previewImage : nil,
                initials: initials,
                name: account.displayName,
                subtitle: farm.name + " · " + Bundle.main.localizedString(
                    forKey: farm.role.displayName, value: farm.role.displayName, table: nil
                ),
                layout: layout,
                supportsIsland: metrics.supportsIsland,
                sourceHidden: motion.isSourceHidden,
                darkAppearance: colorScheme == .dark,
                displayScale: displayScale,
                motion: motion,
                onMetrics: { value in
                    if metrics != value { metrics = value }
                    motion.updateAvailableWidth(value.width)
                    motion.updateTitleHeight(SettingsAvatarTypography.titleHeight)
                }
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                motion.updateAvailableHeight(height)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: SettingsAvatarThumbnailRequest(
            digest: digest,
            pixelSide: Int(ceil(max(100, motion.availableWidth) * displayScale))
        )) {
            let requestedDigest = digest
            guard let data = account.avatarImageData else { return }
            let side = max(100, motion.availableWidth)
            let loaded = await ImageThumbnailPipeline.shared.thumbnail(
                data: data, digest: requestedDigest,
                targetSize: CGSize(width: side, height: side), scale: displayScale
            )
            guard !Task.isCancelled, requestedDigest == digest, let loaded else { return }
            motion.storePreview(loaded, digest: requestedDigest)
        }
    }

    private var digest: String {
        account.avatarCloudDigest ??
            "account-avatar|\(account.id.uuidString)|\(account.updatedAt.timeIntervalSince1970)|\(account.avatarImageData?.count ?? 0)"
    }

    private var initials: String {
        account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .first.map(String.init) ?? "羊"
    }
}

private struct SettingsAvatarThumbnailRequest: Hashable {
    let digest: String
    let pixelSide: Int
}

@MainActor
private enum SettingsAvatarTypography {
    static var titleFont: UIFont { .systemFont(ofSize: 28, weight: .medium) }
    static var titleHeight: CGFloat { floor(titleFont.ascender - titleFont.descender) }
    static var subtitleHeight: CGFloat {
        let font = UIFont.systemFont(ofSize: 17)
        return floor(font.ascender - font.descender)
    }
}

private struct SettingsAvatarRenderLayout {
    let width: CGFloat
    let expandedSide: CGFloat
    let statusBarHeight: CGFloat
    let windowOrigin: CGPoint
    let offset: CGFloat
    let titleProgress: CGFloat
    let expansion: CGFloat
    let animationsEnabled: Bool

    var maskProgress: CGFloat {
        animationsEnabled ? boundedSettingsAvatarProgress(offset / 120) * (1 - expansion) : 0
    }

    var photoFrame: CGRect {
        let fraction = boundedSettingsAvatarProgress(titleProgress)
        let normalScale = animationsEnabled ? 1 - 0.45 * fraction : 1
        let normalSide = 100 * normalScale
        let normalCenterY = statusBarHeight + 72 - offset + (animationsEnabled ? 17 * fraction : 0)
        let pull = animationsEnabled ? max(0, -offset / expandedSide) : 0
        let stretchedSide = expandedSide * (1 + pull)
        // Stretch around the square's center. For a negative offset this keeps
        // its upper edge at the screen top and grows the lower edge with the pull.
        let expandedTop = -offset / 2 - (stretchedSide - expandedSide) / 2
        let normalTop = normalCenterY - normalSide / 2
        let side = normalSide + (stretchedSide - normalSide) * expansion
        let top = normalTop + (expandedTop - normalTop) * expansion
        return CGRect(
            x: windowOrigin.x + (width - side) / 2,
            y: windowOrigin.y + top,
            width: side, height: side
        )
    }

    var cornerRadius: CGFloat {
        photoFrame.width / 2 * (1 - expansion)
    }

    var extensionHeight: CGFloat { 60 * expansion }
}

private struct SettingsAvatarWindowMetrics: Equatable, Sendable {
    let width: CGFloat
    let statusBarHeight: CGFloat
    let windowOriginInView: CGPoint
    let supportsIsland: Bool

    static let empty = Self(
        width: 0, statusBarHeight: 0, windowOriginInView: .zero, supportsIsland: false
    )
}

@MainActor
private struct SettingsAvatarRenderer: UIViewRepresentable {
    let image: UIImage?
    let initials: String
    let name: String
    let subtitle: String
    let layout: SettingsAvatarRenderLayout
    let supportsIsland: Bool
    let sourceHidden: Bool
    let darkAppearance: Bool
    let displayScale: CGFloat
    let motion: AccountAvatarMotionCoordinator
    let onMetrics: @MainActor (SettingsAvatarWindowMetrics) -> Void

    func makeUIView(context: Context) -> SettingsAvatarRendererUIView {
        let view = SettingsAvatarRendererUIView(frame: .zero)
        view.onMetrics = onMetrics
        view.onAttach = { [weak motion] renderer in
            // The coordinator owns a weak query closure, not the renderer.
            motion?.installRendererSourceProvider { [weak renderer] in
                renderer?.transitionSource()
            }
        }
        return view
    }

    func updateUIView(_ uiView: SettingsAvatarRendererUIView, context: Context) {
        uiView.onMetrics = onMetrics
        uiView.render(
            image: image, initials: initials, name: name, subtitle: subtitle,
            layout: layout, supportsIsland: supportsIsland,
            sourceHidden: sourceHidden, darkAppearance: darkAppearance,
            displayScale: displayScale
        )
    }

    static func dismantleUIView(_ uiView: SettingsAvatarRendererUIView, coordinator: ()) {
        // Never erase a newer renderer's registered provider. Its weak capture
        // naturally becomes nil when this renderer is released.
        uiView.invalidate()
    }
}

@MainActor
private final class SettingsAvatarRendererUIView: UIView {
    var onMetrics: (@MainActor (SettingsAvatarWindowMetrics) -> Void)?
    var onAttach: (@MainActor (SettingsAvatarRendererUIView) -> Void)?

    private let clippingView = UIView()
    private let composite = UIView()
    private let photo = UIImageView()
    private let fallback = UILabel()
    private let extensionClip = UIView()
    private let mirroredPhoto = UIImageView()
    private let canvas = UIView()
    private let blackUnderlay = UIView()
    private let islandEffect = AvatarIslandEffectUIView(frame: .zero)
    private let compositeMask = CAShapeLayer()
    private let shadow = CAGradientLayer()
    private let title = UILabel()
    private let subtitle = UILabel()
    private var lastMetrics: SettingsAvatarWindowMetrics?
    private var pendingMetrics: Task<Void, Never>?
    private var pendingAttach: Task<Void, Never>?
    private var renderLayout: SettingsAvatarRenderLayout?
    private var islandEligible = false
    private var renderDisplayScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
        clippingView.clipsToBounds = true
        addSubview(clippingView)
        clippingView.addSubview(composite)
        composite.layer.mask = compositeMask

        canvas.backgroundColor = .clear
        blackUnderlay.backgroundColor = .black
        canvas.addSubview(blackUnderlay)
        composite.addSubview(canvas)
        photo.contentMode = .scaleAspectFill
        photo.clipsToBounds = true
        composite.addSubview(photo)
        fallback.textAlignment = .center
        fallback.clipsToBounds = true
        composite.addSubview(fallback)
        canvas.addSubview(islandEffect)
        // The effect sits above the real photo while keeping its independent
        // 171pt canvas, so the neck has pixels even outside the photo rectangle.
        islandEffect.removeFromSuperview()
        composite.addSubview(islandEffect)

        extensionClip.clipsToBounds = true
        mirroredPhoto.contentMode = .scaleAspectFill
        mirroredPhoto.transform = CGAffineTransform(scaleX: 1, y: -1)
        extensionClip.addSubview(mirroredPhoto)
        composite.addSubview(extensionClip)
        shadow.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.18).cgColor,
            UIColor.black.withAlphaComponent(0.68).cgColor
        ]
        shadow.locations = [0, 0.35, 1]
        composite.layer.addSublayer(shadow)

        title.numberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        subtitle.numberOfLines = 1
        subtitle.lineBreakMode = .byTruncatingTail
        addSubview(title)
        addSubview(subtitle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshMetrics()
        pendingAttach?.cancel()
        if window != nil {
            pendingAttach = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self, self.window != nil else { return }
                self.pendingAttach = nil
                self.onAttach?(self)
            }
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        refreshMetrics()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshMetrics()
        if let renderLayout { applyGeometry(renderLayout) }
    }

    func render(
        image: UIImage?, initials: String, name: String, subtitle text: String,
        layout: SettingsAvatarRenderLayout, supportsIsland: Bool,
        sourceHidden: Bool, darkAppearance: Bool, displayScale: CGFloat
    ) {
        renderLayout = layout
        islandEligible = supportsIsland && layout.animationsEnabled
        renderDisplayScale = max(1, displayScale)
        photo.image = image
        mirroredPhoto.image = image
        fallback.text = initials
        fallback.isHidden = image != nil
        let fallbackColor = UIColor(AppTheme.brand)
        fallback.backgroundColor = fallbackColor.withAlphaComponent(darkAppearance ? 0.24 : 0.10)
        fallback.textColor = UIColor(darkAppearance ? AppTheme.brandSoft : AppTheme.brand)
        title.text = name
        subtitle.text = text
        composite.isHidden = sourceHidden
        let progress = supportsIsland ? layout.maskProgress : 0
        let shapeStrength = boundedSettingsAvatarProgress((progress - 0.03) / 0.03)
        canvas.isHidden = progress <= 0.03
        blackUnderlay.alpha = progress
        islandEffect.setProgress(progress)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        compositeMask.path = SettingsAvatarMaskPath.make(
            photo: layout.photoFrame,
            extensionHeight: layout.extensionHeight,
            cornerRadius: layout.cornerRadius,
            maskOrigin: CGPoint(
                x: layout.windowOrigin.x + (layout.width - 171) / 2,
                y: layout.windowOrigin.y + 47.5
            ),
            progress: progress,
            strength: shapeStrength * (1 - layout.expansion)
        )
        CATransaction.commit()

        applyGeometry(layout)
        applyTypography(layout, displayScale: displayScale)
        // Unsupported devices and Reduce Motion use the regular scroll fade.
        let fallbackAlpha = supportsIsland && layout.animationsEnabled
            ? 1 : 1 - boundedSettingsAvatarProgress(layout.titleProgress) * (1 - layout.expansion)
        composite.alpha = fallbackAlpha
    }

    private func applyGeometry(_ layout: SettingsAvatarRenderLayout) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let clipTop = layout.windowOrigin.y + (islandEligible ? 47 * (1 - layout.expansion) : 0)
        clippingView.frame = CGRect(
            x: layout.windowOrigin.x, y: clipTop,
            width: layout.width, height: max(1000, bounds.height)
        )
        clippingView.layer.cornerRadius = islandEligible ? layout.width / 2.5 * (1 - layout.expansion) : 0
        composite.frame = CGRect(
            x: -clippingView.frame.minX, y: -clippingView.frame.minY,
            width: bounds.width, height: max(bounds.height, layout.photoFrame.maxY + 60)
        )
        compositeMask.frame = composite.bounds
        photo.frame = layout.photoFrame
        photo.layer.cornerRadius = layout.cornerRadius
        fallback.frame = layout.photoFrame
        fallback.layer.cornerRadius = layout.cornerRadius
        fallback.font = .systemFont(ofSize: layout.photoFrame.width * 0.36, weight: .medium)
        extensionClip.frame = CGRect(
            x: layout.photoFrame.minX, y: layout.photoFrame.maxY,
            width: layout.photoFrame.width, height: layout.extensionHeight
        )
        extensionClip.alpha = layout.expansion
        mirroredPhoto.bounds = CGRect(origin: .zero, size: layout.photoFrame.size)
        mirroredPhoto.center = CGPoint(x: layout.photoFrame.width / 2, y: layout.photoFrame.height / 2)
        canvas.frame = CGRect(
            x: layout.windowOrigin.x + (layout.width - 171) / 2,
            y: layout.windowOrigin.y + 47.5, width: 171, height: 171
        )
        blackUnderlay.frame = canvas.bounds
        islandEffect.frame = canvas.frame
        shadow.frame = CGRect(
            x: layout.photoFrame.minX,
            y: layout.photoFrame.maxY + layout.extensionHeight - 88,
            width: layout.photoFrame.width, height: 88
        )
        shadow.opacity = Float(layout.expansion)
        CATransaction.commit()
    }

    private func applyTypography(_ layout: SettingsAvatarRenderLayout, displayScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let expansion = layout.expansion
        let fraction = boundedSettingsAvatarProgress(layout.titleProgress)
        let normalTitleScale = 1 - 0.4 * fraction
        let normalSubtitleScale = 1 - 0.2 * fraction
        let titleScale = normalTitleScale + (0.8 - normalTitleScale) * expansion
        let subtitleScale = normalSubtitleScale + (16.0 / 17.0 - normalSubtitleScale) * expansion
        title.font = SettingsAvatarTypography.titleFont
        subtitle.font = .systemFont(ofSize: 17)
        let baseTitleHeight = SettingsAvatarTypography.titleHeight
        let baseSubtitleHeight = SettingsAvatarTypography.subtitleHeight
        let expandedTitleHeight = baseTitleHeight * 0.8
        let expandedSubtitleHeight = baseSubtitleHeight * (16.0 / 17.0)
        let normalMaxWidth = max(0, layout.width - 32)
        let expandedMaxWidth = max(0, layout.expandedSide - 32)
        let titleMaxWidth = normalMaxWidth * normalTitleScale * (1 - expansion) + expandedMaxWidth * expansion
        let subtitleMaxWidth = normalMaxWidth * normalSubtitleScale * (1 - expansion) + expandedMaxWidth * expansion
        let expandedLeft = layout.windowOrigin.x + (layout.width - layout.expandedSide) / 2 + 16
        let nameWidth = min(titleMaxWidth, title.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: baseTitleHeight)).width * titleScale)
        let subtitleWidth = min(subtitleMaxWidth, subtitle.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: baseSubtitleHeight)).width * subtitleScale)
        // One title scales about its center and then locks below the status bar.
        // A fading header plus a separate navigation title creates two names
        // during this interval and puts the smaller one inside the avatar neck.
        let normalOffset = -min(layout.offset, 107 + baseTitleHeight / 2)
        let normalTitleCenterY = layout.windowOrigin.y + layout.statusBarHeight + 131
            + baseTitleHeight / 2 + normalOffset + 7 * fraction
        let normalSubtitleCenterY = layout.windowOrigin.y + layout.statusBarHeight + 131
            + baseTitleHeight + 1 + baseSubtitleHeight / 2 + normalOffset - 2 * fraction
        let expandedTop = layout.windowOrigin.y + layout.expandedSide + 60 - 58
            - 1 / max(1, displayScale) - layout.offset
        let expandedTitleCenterY = expandedTop + expandedTitleHeight / 2
        let expandedSubtitleCenterY = expandedTop + expandedTitleHeight + 2 + expandedSubtitleHeight / 2
        let titleCenterY = normalTitleCenterY + (expandedTitleCenterY - normalTitleCenterY) * expansion
        let subtitleCenterY = normalSubtitleCenterY + (expandedSubtitleCenterY - normalSubtitleCenterY) * expansion
        let nameX = layout.windowOrigin.x + (layout.width - nameWidth) / 2
        let subX = layout.windowOrigin.x + (layout.width - subtitleWidth) / 2
        // Keep text layout stable while the container scales; changing the
        // font every scroll sample reflows text and rounds its height in steps.
        title.bounds = CGRect(
            x: 0, y: 0, width: nameWidth / titleScale, height: baseTitleHeight
        )
        title.center = CGPoint(
            x: nameX + (expandedLeft - nameX) * expansion + nameWidth / 2,
            y: titleCenterY
        )
        title.transform = CGAffineTransform(scaleX: titleScale, y: titleScale)
        subtitle.bounds = CGRect(
            x: 0, y: 0, width: subtitleWidth / subtitleScale, height: baseSubtitleHeight
        )
        subtitle.center = CGPoint(
            x: subX + (expandedLeft - subX) * expansion + subtitleWidth / 2,
            y: subtitleCenterY
        )
        subtitle.transform = CGAffineTransform(scaleX: subtitleScale, y: subtitleScale)
        let normalColor = UIColor.label.resolvedColor(with: traitCollection)
        let normalSubtitle = UIColor.secondaryLabel.resolvedColor(with: traitCollection)
        title.textColor = blendedSettingsAvatarColor(normalColor, .white, progress: expansion)
        subtitle.textColor = blendedSettingsAvatarColor(normalSubtitle, UIColor.white.withAlphaComponent(0.9), progress: expansion)
        title.alpha = 1
        subtitle.alpha = 1 - fraction * (1 - expansion)
    }

    func transitionSource() -> AccountAvatarTransitionSource? {
        guard let window, !photo.bounds.isEmpty else { return nil }
        let image: UIImage
        if let decoded = photo.image {
            image = decoded
        } else {
            // Gallery must remain reachable while the first thumbnail decodes.
            // Rendering this bounded placeholder also works when its ancestor
            // is hidden during the gallery's return transition.
            let format = UIGraphicsImageRendererFormat()
            format.scale = renderDisplayScale
            format.opaque = false
            image = UIGraphicsImageRenderer(size: fallback.bounds.size, format: format).image { context in
                fallback.layer.render(in: context.cgContext)
            }
        }
        let sourceLayer = photo.layer.presentation() ?? photo.layer
        let targetLayer = window.layer.presentation() ?? window.layer
        let frame = sourceLayer.convert(sourceLayer.bounds, to: targetLayer)
        guard !frame.isEmpty else { return nil }
        return AccountAvatarTransitionSource(
            frameInWindow: frame, image: image,
            cornerRadius: sourceLayer.cornerRadius, window: window
        )
    }

    private func refreshMetrics() {
        guard let window, !bounds.isEmpty else { return }
        let value = settingsAvatarWindowMetrics(view: self, window: window)
        guard lastMetrics != value else { return }
        lastMetrics = value
        pendingMetrics?.cancel()
        pendingMetrics = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.pendingMetrics = nil
            self.onMetrics?(value)
        }
    }

    func invalidate() {
        pendingMetrics?.cancel()
        pendingAttach?.cancel()
        pendingMetrics = nil
        pendingAttach = nil
        onMetrics = nil
        onAttach = nil
        islandEffect.setProgress(0)
    }
}

/// Original control points, guided by Telegram's mask phase timing and bounds.
/// This is an approximation of UserAvatarMask, not a copy of its TGS vectors.
private enum SettingsAvatarMaskPath {
    private struct Cubic {
        var end: CGPoint
        var first: CGPoint
        var second: CGPoint
    }

    private struct Outline {
        var start: CGPoint
        var curves: [Cubic]
    }

    // These are authored silhouette envelopes, not animation vertices. The
    // shoulder may be wider than the body, especially during the final tuck.
    private struct Phase {
        let offset: CGFloat
        let bodyX: CGFloat
        let bodyY: CGFloat
        let bottom: CGFloat
        let neckX: CGFloat
        let neckY: CGFloat
    }

    private static let attachmentPhase = Phase(offset: 34, bodyX: 39.7, bodyY: 49.8, bottom: 88.8, neckX: 20.2, neckY: 8.4)

    private static let phases: [Phase] = [
        Phase(offset: 0, bodyX: 50.1, bodyY: 78.2, bottom: 128.3, neckX: 0, neckY: 28.1),
        Phase(offset: 20, bodyX: 44.1, bodyY: 61.3, bottom: 105.2, neckX: 0, neckY: 16.4),
        Phase(offset: 24.67, bodyX: 42.6, bodyY: 56.7, bottom: 99.7, neckX: 0, neckY: 9.2),
        Phase(offset: 26.67, bodyX: 41.9, bodyY: 55.3, bottom: 97.5, neckX: 0, neckY: -0.7),
        Phase(offset: 33.33, bodyX: 39.7, bodyY: 49.3, bottom: 89.5, neckX: 0, neckY: -0.7),
        attachmentPhase,
        Phase(offset: 40, bodyX: 37.7, bodyY: 43.8, bottom: 81.8, neckX: 24.2, neckY: 9.0),
        Phase(offset: 53.33, bodyX: 33.4, bodyY: 33.7, bottom: 66.3, neckX: 28.9, neckY: 10.4),
        Phase(offset: 73.33, bodyX: 24.2, bodyY: 28.1, bottom: 42.9, neckX: 30.6, neckY: 6.8),
        Phase(offset: 93.33, bodyX: 19.7, bodyY: 7.7, bottom: 19.4, neckX: 27.4, neckY: 1.8),
        Phase(offset: 110.67, bodyX: 12, bodyY: 0, bottom: 0, neckX: 24, neckY: 0),
        Phase(offset: 120, bodyX: 12, bodyY: 0, bottom: 0, neckX: 24, neckY: 0)
    ]

    // The island first reaches down as a separate tongue. It grows into the
    // photo before the connected shoulder takes over; reverse scroll samples
    // exactly the same geometry without a timed attachment animation.
    private static let tonguePhases: [Phase] = [
        Phase(offset: 16.67, bodyX: 12, bodyY: 0, bottom: 0, neckX: 24, neckY: 0),
        Phase(offset: 24.67, bodyX: 10, bodyY: 3.5, bottom: 5.7, neckX: 12, neckY: 2.4),
        Phase(offset: 25.33, bodyX: 6.8, bodyY: 8.4, bottom: 10.7, neckX: 7, neckY: 5.8),
        Phase(offset: 25.78, bodyX: 8, bodyY: 10.5, bottom: 13.3, neckX: 7.6, neckY: 5.2),
        Phase(offset: 33.33, bodyX: 25, bodyY: 40, bottom: 57.4, neckX: 19.5, neckY: 8.7),
        Phase(offset: 33.78, bodyX: 25, bodyY: 40, bottom: 57.4, neckX: 19.5, neckY: 8.7),
        attachmentPhase
    ]

    static func make(
        photo: CGRect, extensionHeight: CGFloat, cornerRadius: CGFloat,
        maskOrigin: CGPoint, progress: CGFloat, strength: CGFloat
    ) -> CGPath {
        let regular = rounded(
            CGRect(x: photo.minX, y: photo.minY, width: photo.width, height: photo.height + extensionHeight),
            radius: cornerRadius
        )
        let offset = boundedSettingsAvatarProgress(progress) * 120
        let phase = sample(phases, at: offset)
        let joined = boundedSettingsAvatarProgress((offset - 33.33) / 0.67)
        let collapsed = body(phase, origin: maskOrigin, joined: joined, offset: offset)
        let strength = boundedSettingsAvatarProgress(strength)
        let path = CGMutablePath()
        path.move(to: blend(regular.start, collapsed.start, strength))
        for index in regular.curves.indices {
            let a = regular.curves[index]
            let b = collapsed.curves[index]
            path.addCurve(
                to: blend(a.end, b.end, strength),
                control1: blend(a.first, b.first, strength),
                control2: blend(a.second, b.second, strength)
            )
        }
        path.closeSubpath()
        let connection = offset < 34 ? sample(tonguePhases, at: offset) : phase
        appendConnection(connection, origin: maskOrigin, strength: strength, to: path)
        return path
    }

    private static func sample(_ values: [Phase], at offset: CGFloat) -> Phase {
        let upper = values.firstIndex(where: { $0.offset >= offset }) ?? (values.count - 1)
        let a = values[max(0, upper - 1)], b = values[upper]
        let fraction = boundedSettingsAvatarProgress(
            b.offset > a.offset ? (offset - a.offset) / (b.offset - a.offset) : 0
        )
        func mix(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
            first + (second - first) * fraction
        }
        return Phase(
            offset: offset, bodyX: mix(a.bodyX, b.bodyX), bodyY: mix(a.bodyY, b.bodyY),
            bottom: mix(a.bottom, b.bottom), neckX: mix(a.neckX, b.neckX), neckY: mix(a.neckY, b.neckY)
        )
    }

    private static func rounded(_ rect: CGRect, radius: CGFloat) -> Outline {
        let r = min(max(0, radius), min(rect.width, rect.height) / 2)
        let k = r * 0.5522847498307936
        let l = rect.minX, t = rect.minY, b = rect.maxY, z = rect.maxX
        let points = [
            CGPoint(x: l + r, y: t), CGPoint(x: z - r, y: t),
            CGPoint(x: z, y: t + r), CGPoint(x: z, y: b - r),
            CGPoint(x: z - r, y: b), CGPoint(x: l + r, y: b),
            CGPoint(x: l, y: b - r), CGPoint(x: l, y: t + r)
        ]
        return Outline(start: points[0], curves: [
            straight(points[0], points[1]),
            Cubic(end: points[2], first: CGPoint(x: z-r+k, y: t), second: CGPoint(x: z, y: t+r-k)),
            straight(points[2], points[3]),
            Cubic(end: points[4], first: CGPoint(x: z, y: b-r+k), second: CGPoint(x: z-r+k, y: b)),
            straight(points[4], points[5]),
            Cubic(end: points[6], first: CGPoint(x: l+r-k, y: b), second: CGPoint(x: l, y: b-r+k)),
            straight(points[6], points[7]),
            Cubic(end: points[0], first: CGPoint(x: l, y: t+r-k), second: CGPoint(x: l+r-k, y: t))
        ])
    }

    private static func body(_ phase: Phase, origin: CGPoint, joined: CGFloat, offset: CGFloat) -> Outline {
        let cx = origin.x + 85.5
        let left = CGPoint(x: cx - phase.neckX, y: origin.y + phase.neckY)
        let right = CGPoint(x: cx + phase.neckX, y: left.y)
        let east = CGPoint(x: cx + phase.bodyX, y: origin.y + phase.bodyY)
        let south = CGPoint(x: cx, y: origin.y + phase.bottom)
        let west = CGPoint(x: cx - phase.bodyX, y: east.y)
        let height = max(0, phase.bodyY - phase.neckY)
        let taper = boundedSettingsAvatarProgress((offset - 20) / 4.67)
        let detachedHandle = phase.bodyX * (0.5523 - 0.46 * taper)
        let shoulderInset = max(0, phase.neckX - phase.bodyX)
        let connectedFirst = CGPoint(x: right.x - shoulderInset * 0.34, y: right.y + height * 0.3)
        let connectedSecond = CGPoint(x: east.x + shoulderInset * 0.4, y: east.y - height * 0.55)
        let upperFirst = blend(CGPoint(x: right.x + detachedHandle, y: right.y), connectedFirst, joined)
        let upperSecond = blend(CGPoint(x: east.x, y: east.y - height * 0.55), connectedSecond, joined)
        let lowerHeight = max(0, phase.bottom - phase.bodyY)
        let late = boundedSettingsAvatarProgress((offset - 73.33) / 20)
        let sideHandle = lowerHeight * (0.5 - 0.2 * late)
        let sideInset = height > 0 ? shoulderInset * 0.4 * sideHandle / (height * 0.55) * joined : 0
        let bottomHandle = phase.bodyX * 0.58
        return Outline(start: left, curves: [
            straight(left, right),
            Cubic(end: east, first: upperFirst, second: upperSecond),
            straight(east, east),
            Cubic(end: south, first: CGPoint(x: east.x - sideInset, y: east.y + sideHandle), second: CGPoint(x: cx + bottomHandle, y: south.y)),
            straight(south, south),
            Cubic(end: west, first: CGPoint(x: cx - bottomHandle, y: south.y), second: CGPoint(x: west.x + sideInset, y: west.y + sideHandle)),
            straight(west, west),
            Cubic(end: left, first: CGPoint(x: 2 * cx - upperSecond.x, y: upperSecond.y), second: CGPoint(x: 2 * cx - upperFirst.x, y: upperFirst.y))
        ])
    }

    private static func appendConnection(
        _ phase: Phase, origin: CGPoint, strength: CGFloat, to path: CGMutablePath
    ) {
        let cx = origin.x + 85.5
        let halfWidth: CGFloat = 48.4
        let lip: CGFloat = 45.7
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + x, y: origin.y + y * strength)
        }
        let right = point(phase.neckX, phase.neckY)
        let topHandle = min(phase.neckY * 1.08, max(0, phase.bodyX - 16) * 0.5)
        let neckToBody = max(0, phase.bodyY - phase.neckY)
        let shoulderInset = max(0, phase.neckX - phase.bodyX)
        let lowerHeight = max(0, phase.bottom - phase.bodyY)
        let late = boundedSettingsAvatarProgress((phase.offset - 73.33) / 20)
        let sideHandle = lowerHeight * (0.5 - 0.2 * late)
        // Share each join's tangent across its two curves. This matters when
        // the late shoulder widens beyond the body and becomes a shallow bowl.
        let neckInset = neckToBody > 0 ? shoulderInset * 0.34 * topHandle / (neckToBody * 0.3) : 0
        let sideInset = neckToBody > 0 ? shoulderInset * 0.4 * sideHandle / (neckToBody * 0.55) : 0
        path.move(to: point(-halfWidth, -1.67))
        path.addLine(to: point(halfWidth, -1.67))
        path.addLine(to: point(halfWidth, 0))
        path.addLine(to: point(lip, 0))
        path.addCurve(
            to: right,
            control1: point(lip - (lip - phase.neckX) * 0.2, 0),
            control2: point(phase.neckX + neckInset, phase.neckY - topHandle)
        )
        path.addCurve(
            to: point(phase.bodyX, phase.bodyY),
            control1: point(phase.neckX - shoulderInset * 0.34, phase.neckY + neckToBody * 0.3),
            control2: point(phase.bodyX + shoulderInset * 0.4, phase.bodyY - neckToBody * 0.55)
        )
        path.addCurve(
            to: point(0, phase.bottom),
            control1: point(phase.bodyX - sideInset, phase.bodyY + sideHandle),
            control2: point(phase.bodyX * 0.58, phase.bottom)
        )
        path.addCurve(
            to: point(-phase.bodyX, phase.bodyY),
            control1: point(-phase.bodyX * 0.58, phase.bottom),
            control2: point(-phase.bodyX + sideInset, phase.bodyY + sideHandle)
        )
        path.addCurve(
            to: point(-phase.neckX, phase.neckY),
            control1: point(-phase.bodyX - shoulderInset * 0.4, phase.bodyY - neckToBody * 0.55),
            control2: point(-phase.neckX + shoulderInset * 0.34, phase.neckY + neckToBody * 0.3)
        )
        path.addCurve(
            to: point(-lip, 0),
            control1: point(-phase.neckX - neckInset, phase.neckY - topHandle),
            control2: point(-lip + (lip - phase.neckX) * 0.2, 0)
        )
        path.addLine(to: point(-halfWidth, 0))
        path.closeSubpath()
    }

    private static func straight(_ start: CGPoint, _ end: CGPoint) -> Cubic {
        Cubic(end: end, first: blend(start, end, 1/3), second: blend(start, end, 2/3))
    }

    private static func blend(_ a: CGPoint, _ b: CGPoint, _ p: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x-a.x)*p, y: a.y + (b.y-a.y)*p)
    }
}

@MainActor
private struct SettingsAvatarWindowProbe: UIViewRepresentable {
    let onUpdate: @MainActor (SettingsAvatarWindowMetrics) -> Void

    func makeUIView(context: Context) -> SettingsAvatarWindowProbeUIView {
        let view = SettingsAvatarWindowProbeUIView(frame: .zero)
        view.onUpdate = onUpdate
        return view
    }

    func updateUIView(_ uiView: SettingsAvatarWindowProbeUIView, context: Context) {
        uiView.onUpdate = onUpdate
        uiView.refresh()
    }

    static func dismantleUIView(_ uiView: SettingsAvatarWindowProbeUIView, coordinator: ()) {
        uiView.invalidate()
    }
}

@MainActor
private final class SettingsAvatarWindowProbeUIView: UIView {
    var onUpdate: (@MainActor (SettingsAvatarWindowMetrics) -> Void)?
    private var last: SettingsAvatarWindowMetrics?
    private var pending: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() { super.didMoveToWindow(); refresh() }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); refresh() }
    override func layoutSubviews() { super.layoutSubviews(); refresh() }

    func refresh() {
        guard let window, !bounds.isEmpty else { return }
        let metrics = settingsAvatarWindowMetrics(view: self, window: window)
        guard last != metrics else { return }
        last = metrics
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.onUpdate?(metrics)
        }
    }

    func invalidate() { pending?.cancel(); pending = nil; onUpdate = nil }
}

@MainActor
private func settingsAvatarWindowMetrics(view: UIView, window: UIWindow) -> SettingsAvatarWindowMetrics {
    let status = window.windowScene?.statusBarManager?.statusBarFrame.height ?? window.safeAreaInsets.top
    let portrait = window.windowScene?.effectiveGeometry.interfaceOrientation.isPortrait
        ?? (window.bounds.height > window.bounds.width)
    return SettingsAvatarWindowMetrics(
        width: window.bounds.width,
        statusBarHeight: status,
        windowOriginInView: view.convert(.zero, from: window),
        supportsIsland: window.traitCollection.userInterfaceIdiom == .phone
            && portrait && window.safeAreaInsets.top >= 59
            && window.windowScene?.statusBarManager?.isStatusBarHidden != true
    )
}

private func settingsAvatarExpandedSide(width: CGFloat, height: CGFloat) -> CGFloat {
    // The overlay supplies the viewport height, never the animated header's
    // reserved height. Portrait keeps a full-width square; shorter windows
    // preserve room for the 60pt extension and its visible account title.
    guard height.isFinite, height > 0 else { return width }
    return min(width, max(100, height - 60))
}

private func boundedSettingsAvatarProgress(_ value: CGFloat) -> CGFloat {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
}

@MainActor
private func blendedSettingsAvatarColor(_ from: UIColor, _ to: UIColor, progress: CGFloat) -> UIColor {
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    from.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    to.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return UIColor(
        red: r1 + (r2-r1)*progress, green: g1 + (g2-g1)*progress,
        blue: b1 + (b2-b1)*progress, alpha: a1 + (a2-a1)*progress
    )
}
